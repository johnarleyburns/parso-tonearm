import Foundation
import XCTest
@testable import TonearmCore

/// Test-only analysis of the 36 Starter tracks, used to synthesize audio and to seed catalog rows.
/// Production starter definitions carry no per-track facts; catalog data is authoritative there.
enum StarterTestFacts {
    static let all: [StarterTrackFacts] = [
        StarterTrackFacts(id: "337997", durationSeconds: 251.17024943310656, bpm: 82.17130077313021, beatPeriod: 0.7301819423019263, beatPhase: 0.09507577373722999, rmsDB: -8.6795234546563),
        StarterTrackFacts(id: "1424003", durationSeconds: 232.50140589569162, bpm: 80.0061675331234, beatPeriod: 0.749942183834257, beatPhase: 0.1054606196016924, rmsDB: -13.851425748577885),
        StarterTrackFacts(id: "337069", durationSeconds: 197.53215419501134, bpm: 84.01, beatPeriod: 0.7142006903940007, beatPhase: 0.0, rmsDB: -10.310832484446362),
        StarterTrackFacts(id: "1180864", durationSeconds: 171.96698412698413, bpm: 80.0267458800018, beatPeriod: 0.7497493411761185, beatPhase: 0.6091713397055962, rmsDB: -10.820968604727387),
        StarterTrackFacts(id: "642026", durationSeconds: 200.57396825396825, bpm: 84.00569103928542, beatPeriod: 0.714237324372951, beatPhase: 0.011159958193327359, rmsDB: -11.099004980942802),
        StarterTrackFacts(id: "1077690", durationSeconds: 325.8224036281179, bpm: 85.18264221518415, beatPeriod: 0.7043688530866534, beatPhase: 0.10272045774180362, rmsDB: -11.951764711449758),
        StarterTrackFacts(id: "455018", durationSeconds: 127.19891156462585, bpm: 78.09009438458943, beatPeriod: 0.7683432895407104, beatPhase: 0.1440643667888832, rmsDB: -13.916226665197906),
        StarterTrackFacts(id: "117009", durationSeconds: 304.22784580498865, bpm: 78.1876494598568, beatPeriod: 0.7673846242277084, beatPhase: 0.4236602612923807, rmsDB: -14.13638892259643),
        StarterTrackFacts(id: "971563", durationSeconds: 258.9953741496599, bpm: 80.07758257765207, beatPeriod: 0.7492733680092974, beatPhase: 0.6595166624665171, rmsDB: -16.72719226794386),
        StarterTrackFacts(id: "1097061", durationSeconds: 369.0347392290249, bpm: 80.14127734156519, beatPeriod: 0.7486778597785222, beatPhase: 0.03899363853013136, rmsDB: -11.326239537885531),
        StarterTrackFacts(id: "26403", durationSeconds: 175.72861678004534, bpm: 80.09820992005314, beatPeriod: 0.7490804109091406, beatPhase: 0.4408650335038171, rmsDB: -17.65465264711421),
        StarterTrackFacts(id: "1100130", durationSeconds: 264.21986394557825, bpm: 80.00497101653811, beatPeriod: 0.7499533996155963, beatPhase: 0.214830400931551, rmsDB: -8.758621318301337),
        StarterTrackFacts(id: "1163782", durationSeconds: 195.97641723356008, bpm: 111.98213095379177, beatPeriod: 0.535799769918277, beatPhase: 0.3013873705790308, rmsDB: -14.795658123420566),
        StarterTrackFacts(id: "1828808", durationSeconds: 107.27619047619048, bpm: 113.00471677382012, beatPeriod: 0.5309512886978912, beatPhase: 0.00829611388590455, rmsDB: -10.561831076395979),
        StarterTrackFacts(id: "1121468", durationSeconds: 170.22548752834467, bpm: 110.00260325708967, beatPeriod: 0.5454416370471942, beatPhase: 0.14772377670028175, rmsDB: -8.481588657470276),
        StarterTrackFacts(id: "1739551", durationSeconds: 268.7245351473923, bpm: 109.9946572171799, beatPeriod: 0.5454810398793505, beatPhase: 0.0, rmsDB: -11.368594781916494),
        StarterTrackFacts(id: "1493402", durationSeconds: 34.92281179138322, bpm: 109.98941377488917, beatPeriod: 0.5455070441851754, beatPhase: 0.025570642696180094, rmsDB: -8.205447461701874),
        StarterTrackFacts(id: "1560522", durationSeconds: 226.92861678004536, bpm: 109.98675750644362, beatPeriod: 0.5455202186179993, beatPhase: 0.0, rmsDB: -8.227164671384141),
        StarterTrackFacts(id: "1229422", durationSeconds: 193.86340136054423, bpm: 63.4588626308157, beatPeriod: 0.9454944118532614, beatPhase: 0.02954670037041442, rmsDB: -7.83149755678347),
        StarterTrackFacts(id: "398193", durationSeconds: 200.59718820861679, bpm: 66.83698942628128, beatPeriod: 0.8977065022681456, beatPhase: 0.3646932665464342, rmsDB: -12.645631336228277),
        StarterTrackFacts(id: "1418240", durationSeconds: 186.084716553288, bpm: 65.99493098129284, beatPeriod: 0.9091607356481336, beatPhase: 0.014205636494502087, rmsDB: -8.772427752748523),
        StarterTrackFacts(id: "1308980", durationSeconds: 167.32299319727892, bpm: 68.02171179288578, beatPeriod: 0.8820713036844693, beatPhase: 0.3859061953619553, rmsDB: -8.385781393039359),
        StarterTrackFacts(id: "1849464", durationSeconds: 278.3375963718821, bpm: 71.0183023763587, beatPeriod: 0.844852636465912, beatPhase: 0.16281014348561848, rmsDB: -14.915069222802861),
        StarterTrackFacts(id: "1212932", durationSeconds: 255.23374149659864, bpm: 72.51114862242335, beatPeriod: 0.8274589651369224, beatPhase: 0.1034323706421153, rmsDB: -10.838539223084052),
        StarterTrackFacts(id: "2053669", durationSeconds: 133.09678004535147, bpm: 124.02434072820601, beatPeriod: 0.4837760043529472, beatPhase: 0.40062700360478437, rmsDB: -11.329279263944825),
        StarterTrackFacts(id: "2228244", durationSeconds: 194.95473922902494, bpm: 124.99934151388197, beatPeriod: 0.48000252860001363, beatPhase: 0.0800004214333356, rmsDB: -8.12038927532982),
        StarterTrackFacts(id: "1901830", durationSeconds: 168.0195918367347, bpm: 119.99533964696505, beatPeriod: 0.500019418891803, beatPhase: 0.007812803420184422, rmsDB: -11.161333434039896),
        StarterTrackFacts(id: "2126638", durationSeconds: 290.0172335600907, bpm: 119.98194786847543, beatPeriod: 0.500075228531647, beatPhase: 0.20315556159098158, rmsDB: -6.179778856710484),
        StarterTrackFacts(id: "2133921", durationSeconds: 132.0518820861678, bpm: 119.99193730611272, beatPeriod: 0.500033596815204, beatPhase: 0.015626049900475125, rmsDB: -11.43390043428559),
        StarterTrackFacts(id: "1977152", durationSeconds: 89.39682539682539, bpm: 120.0000686317002, beatPeriod: 0.499999714034746, beatPhase: 0.37499978552605956, rmsDB: -9.30103699501068),
        StarterTrackFacts(id: "1891078", durationSeconds: 103.05015873015873, bpm: 67.56485251606945, beatPeriod: 0.8880356837266795, beatPhase: 0.26363559360635797, rmsDB: -22.786895605264522),
        StarterTrackFacts(id: "1891935", durationSeconds: 121.13850340136054, bpm: 66.89861821823668, beatPeriod: 0.8968795110874787, beatPhase: 0.40172728100793315, rmsDB: -13.760945110489),
        StarterTrackFacts(id: "1974389", durationSeconds: 150.00090702947847, bpm: 70.1241370256391, beatPeriod: 0.8556255027860454, beatPhase: 0.3386850948528097, rmsDB: -17.778085848274824),
        StarterTrackFacts(id: "2220789", durationSeconds: 206.77369614512472, bpm: 69.99, beatPeriod: 0.8572653236176597, beatPhase: 0.14287755393627663, rmsDB: -19.764969437747236),
        StarterTrackFacts(id: "2169489", durationSeconds: 131.86612244897958, bpm: 70.0, beatPeriod: 0.8571428571428571, beatPhase: 0.46875, rmsDB: -18.67941839045606),
        StarterTrackFacts(id: "1960412", durationSeconds: 167.32299319727892, bpm: 73.9982122443568, beatPeriod: 0.8108303995489524, beatPhase: 0.1478076249177778, rmsDB: -14.340025827591958),
    ]
    static let byID: [String: StarterTrackFacts] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// The fetched `Resources/Starter/starter.sqlite` can predate `StarterLibrary.formatVersion` until the
/// current pack is assembled; tests that read the bundled catalog skip (visibly) instead of failing on it.
func requireCurrentStarterCatalog() throws {
    do {
        _ = try StarterCatalogAdapter.bundled().contentVersion()
    } catch StarterCatalogError.unavailable {
        throw XCTSkip("Resources/Starter/starter.sqlite is not present (make starter)")
    } catch StarterCatalogError.incompatibleVersion(let found) {
        throw XCTSkip("Resources/Starter/starter.sqlite is format \(found); needs \(StarterLibrary.formatVersion)")
    }
}
