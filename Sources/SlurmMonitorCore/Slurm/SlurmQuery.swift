import Foundation

/// Errors thrown while parsing remote Slurm query output.
public enum SlurmQueryError: Error, Equatable, Sendable {
    case commandFailed(String)
    case malformed
}

/// Remote shell query script and parser for `squeue` / `sacct` output.
public enum SlurmQuery {
    private enum Section {
        case preamble
        case active
        case start
        case ended
        case done
    }

    private static let activeFieldCount = 15
    private static let startFieldCount = 2
    private static let endedFieldCount = 6

    /// Self-delimited shell script executed over SSH via `bash -l -s`.
    public static let remoteScript = #"""
    echo '@@ACTIVE'
    squeue -u "$USER" -h -o '%i|%j|%T|%P|%a|%M|%l|%D|%C|%m|%b|%R|%V|%S|%Z' || echo "@@ERR squeue $?"
    echo '@@START'
    squeue -u "$USER" -h -t PD --start -o '%i|%S' 2>/dev/null || true
    echo '@@ENDED'
    sacct -u "$USER" -X -n -P -S now-7days -o JobID,JobName,State,ExitCode,End,Elapsed 2>/dev/null || true
    echo '@@DONE'
    """#

    /// Parses output produced by `remoteScript` into a `ClusterSnapshot`.
    public static func parse(_ output: String, clusterID: UUID, fetchedAt: Date) throws -> ClusterSnapshot {
        var section: Section = .preamble
        var sawDone = false
        var activeJobs: [ActiveJob] = []
        var estimatedStarts: [String: Date] = [:]
        var endedJobs: [EndedJob] = []

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : String(rawLine)
            let marker = line.trimmingCharacters(in: .whitespaces)
            if marker.isEmpty { continue }

            if section != .preamble, marker.hasPrefix("@@ERR") {
                throw SlurmQueryError.commandFailed(marker)
            }

            switch marker {
            case "@@ACTIVE":
                section = .active
                continue
            case "@@START":
                section = .start
                continue
            case "@@ENDED":
                section = .ended
                continue
            case "@@DONE":
                sawDone = true
                section = .done
                continue
            default:
                break
            }

            switch section {
            case .preamble, .done:
                continue
            case .active:
                if let job = parseActiveRow(line) {
                    activeJobs.append(job)
                }
            case .start:
                if let (jobID, startDate) = parseStartRow(line), estimatedStarts[jobID] == nil {
                    estimatedStarts[jobID] = startDate
                }
            case .ended:
                if let job = parseEndedRow(line), job.state.isTerminal {
                    endedJobs.append(job)
                }
            }
        }

        guard sawDone else {
            throw SlurmQueryError.malformed
        }

        for index in activeJobs.indices {
            if let estimatedStart = estimatedStarts[activeJobs[index].id] {
                activeJobs[index].estimatedStart = estimatedStart
            }
        }

        return ClusterSnapshot(
            clusterID: clusterID,
            fetchedAt: fetchedAt,
            active: activeJobs,
            ended: endedJobs
        )
    }

    private static func parseActiveRow(_ line: String) -> ActiveJob? {
        guard let fields = splitPipeFields(line, expectedFieldCount: activeFieldCount) else {
            return nil
        }

        let id = fields[0].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }

        return ActiveJob(
            id: id,
            name: fields[1],
            state: JobState(slurm: fields[2]),
            partition: fields[3],
            account: fields[4],
            elapsed: SlurmTime.duration(fields[5]),
            timeLimit: SlurmTime.duration(fields[6]),
            nodes: SlurmTime.nonNullToken(fields[7]).flatMap(Int.init),
            cpus: SlurmTime.nonNullToken(fields[8]).flatMap(Int.init),
            memory: SlurmTime.nonNullToken(fields[9]),
            gpus: SlurmTime.gpuCount(fields[10]),
            reasonOrNodes: fields[11],
            submitTime: SlurmTime.date(fields[12]),
            startTime: SlurmTime.date(fields[13]),
            workDir: SlurmTime.nonNullToken(fields[14]),
            estimatedStart: nil
        )
    }

    private static func parseStartRow(_ line: String) -> (String, Date)? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= startFieldCount else { return nil }
        let id = fields[0].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let date = SlurmTime.date(fields[1]) else { return nil }
        return (id, date)
    }

    private static func parseEndedRow(_ line: String) -> EndedJob? {
        guard let fields = splitPipeFields(line, expectedFieldCount: endedFieldCount) else {
            return nil
        }

        let id = fields[0].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }

        return EndedJob(
            id: id,
            name: fields[1],
            state: JobState(slurm: fields[2]),
            exitCode: fields[3],
            endTime: SlurmTime.date(fields[4]),
            elapsed: SlurmTime.duration(fields[5])
        )
    }

    /// Rejoins any extra pipe-delimited segments back into field 1 (the job name).
    private static func splitPipeFields(_ line: String, expectedFieldCount: Int) -> [String]? {
        let rawFields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard rawFields.count >= expectedFieldCount else { return nil }

        let extra = rawFields.count - expectedFieldCount
        guard extra > 0 else { return rawFields }

        var normalized: [String] = []
        normalized.reserveCapacity(expectedFieldCount)
        normalized.append(rawFields[0])
        normalized.append(rawFields[1...(1 + extra)].joined(separator: "|"))
        normalized.append(contentsOf: rawFields[(2 + extra)...])
        return normalized
    }
}
