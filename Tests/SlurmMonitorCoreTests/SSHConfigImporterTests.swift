import Foundation
import Testing
@testable import SlurmMonitorCore

private let sampleConfig = """
Match final host *.alliancecan.ca exec "/bin/bash x"
    ControlPath ~/.ssh/cmfa-%C
Match all
Host nibi
  HostName nibi.alliancecan.ca
  User leihan
Host narval 
  HostName narval.alliancecan.ca
  User leihan
Host trillium-gpu
  HostName trillium-gpu.scinet.utoronto.ca
  User leihan
Host gpu_server
  HostName gpuclient.cs.torontomu.ca
Host *
  ServerAliveInterval 60
  User fallback_user
"""

@Test func parsesLiteralHostsOnly() {
    let hosts = SSHConfigImporter.parseHosts(sampleConfig)
    #expect(hosts.map(\.alias) == ["nibi", "narval", "trillium-gpu", "gpu_server"])
    #expect(hosts[1] == SSHConfigHost(alias: "narval", hostName: "narval.alliancecan.ca", user: "leihan"))
    #expect(hosts[3] == SSHConfigHost(alias: "gpu_server", hostName: "gpuclient.cs.torontomu.ca", user: nil))
}

@Test func knownDomains() {
    #expect(SSHConfigImporter.isKnownClusterDomain("nibi.alliancecan.ca"))
    #expect(SSHConfigImporter.isKnownClusterDomain("graham.computecanada.ca"))
    #expect(SSHConfigImporter.isKnownClusterDomain("trillium-gpu.scinet.utoronto.ca"))
    #expect(SSHConfigImporter.isKnownClusterDomain("NIBI.ALLIANCECAN.CA"))
    #expect(!SSHConfigImporter.isKnownClusterDomain("gpuclient.cs.torontomu.ca"))
    #expect(!SSHConfigImporter.isKnownClusterDomain("notalliancecan.ca"))
}

@Test func emptyConfigYieldsNoHosts() {
    #expect(SSHConfigImporter.parseHosts("").isEmpty)
    #expect(SSHConfigImporter.parseHosts("\n  # comment only\n\n").isEmpty)
}

@Test func presetsOneUsername() {
    let cs = AlliancePresets.clusters(username: "alice", selected: ["nibi", "trillium-gpu"])
    #expect(cs.map(\.name) == ["nibi", "trillium-gpu"])
    #expect(cs.allSatisfy { $0.username == "alice" })
    #expect(cs[1].requiresKey && !cs[0].requiresKey)
    #expect(AlliancePresets.all.count == 8)
    #expect(AlliancePresets.all.map(\.name) == [
        "nibi", "fir", "narval", "rorqual", "trillium", "trillium-gpu", "tamia", "killarney"
    ])
    #expect(AlliancePresets.all.map(\.host) == [
        "nibi.alliancecan.ca",
        "fir.alliancecan.ca",
        "narval.alliancecan.ca",
        "rorqual.alliancecan.ca",
        "trillium.scinet.utoronto.ca",
        "trillium-gpu.scinet.utoronto.ca",
        "tamia.alliancecan.ca",
        "killarney.alliancecan.ca"
    ])
    #expect(AlliancePresets.clusters(username: "alice", selected: []).isEmpty)
}

@Test func presetsTreatTrilliumAndTrilliumGPUAsSeparateClusters() {
    let cs = AlliancePresets.clusters(username: "alice", selected: ["trillium", "trillium-gpu"])
    #expect(cs.count == 2)
    #expect(cs.map(\.name) == ["trillium", "trillium-gpu"])
    #expect(cs.allSatisfy { $0.requiresKey })
}

@Test func parsesCaseInsensitiveKeywordsEqualsMultiAliasAndMatchBoundary() {
    let config = """
    # Leading comment
    host tamia fir 
      HOSTNAME=tamia.alliancecan.ca 
      user = bob
    Match host *.scinet.utoronto.ca
      User should_not_attach
    HOST web-? !excluded prod-1
      HostName prod1.computecanada.ca
    """
    let hosts = SSHConfigImporter.parseHosts(config)
    #expect(hosts == [
        SSHConfigHost(alias: "tamia", hostName: "tamia.alliancecan.ca", user: "bob"),
        SSHConfigHost(alias: "fir", hostName: "tamia.alliancecan.ca", user: "bob"),
        SSHConfigHost(alias: "prod-1", hostName: "prod1.computecanada.ca", user: nil)
    ])
}

@Test func clusterConversionUsesDefaultsAndRequiresKeyFromPresets() {
    let trilliumHost = SSHConfigHost(
        alias: "trillium",
        hostName: "trillium.scinet.utoronto.ca",
        user: nil
    )
    let trilliumCluster = SSHConfigImporter.cluster(from: trilliumHost, defaultUser: "alice")
    #expect(trilliumCluster.name == "trillium")
    #expect(trilliumCluster.sshAlias == "trillium")
    #expect(trilliumCluster.host == "trillium.scinet.utoronto.ca")
    #expect(trilliumCluster.username == "alice")
    #expect(trilliumCluster.requiresKey == true)

    let fallbackHost = SSHConfigHost(alias: "custom-box", hostName: nil, user: "carol")
    let fallbackCluster = SSHConfigImporter.cluster(from: fallbackHost, defaultUser: "alice")
    #expect(fallbackCluster.name == "custom-box")
    #expect(fallbackCluster.sshAlias == "custom-box")
    #expect(fallbackCluster.host == "custom-box")
    #expect(fallbackCluster.username == "carol")
    #expect(fallbackCluster.requiresKey == false)
}
