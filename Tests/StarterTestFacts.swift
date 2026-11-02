import Foundation
@testable import TonearmCore

/// Test-only analysis of the 36 Starter tracks, used to synthesize audio and to seed catalog rows.
/// Production starter definitions carry no per-track facts; catalog data is authoritative there.
enum StarterTestFacts {
    static let all: [StarterTrackFacts] = [
        StarterTrackFacts(id: "1174818", durationSeconds: 274.02190476190475, bpm: 86.64913073387758, beatPeriod: 0.6924478005933594, beatPhase: 0.32923020394178804, rmsDB: -16.035029709703863),
        StarterTrackFacts(id: "2232438", durationSeconds: 202.61396825396827, bpm: 87.92203592472909, beatPeriod: 0.6824227779639519, beatPhase: 0.626938775510204, rmsDB: -12.554386825767128),
        StarterTrackFacts(id: "1428775", durationSeconds: 294.4533333333333, bpm: 90.05237232639641, beatPeriod: 0.6662789491267254, beatPhase: 0.16963941822021344, rmsDB: -18.150404803824387),
        StarterTrackFacts(id: "2020849", durationSeconds: 253.0, bpm: 94.19188346758588, beatPeriod: 0.6369975606300272, beatPhase: 0.4234123205980457, rmsDB: -10.93356181970637),
        StarterTrackFacts(id: "26742", durationSeconds: 251.97201814058957, bpm: 95.35448581888018, beatPeriod: 0.6292310160841956, beatPhase: 0.3586584776583006, rmsDB: -14.954507302354594),
        StarterTrackFacts(id: "1832242", durationSeconds: 243.0316553287982, bpm: 96.0047846360195, beatPeriod: 0.6249688515783508, beatPhase: 0.5804988662131519, rmsDB: -13.748737746762574),
        StarterTrackFacts(id: "98135", durationSeconds: 370.9842176870748, bpm: 67.9983903758841, beatPeriod: 0.882373827796948, beatPhase: 0.2089795918367347, rmsDB: -12.246303591223572),
        StarterTrackFacts(id: "785424", durationSeconds: 178.9092970521542, bpm: 68.48946090983102, beatPeriod: 0.8760471932899615, beatPhase: 0.2786394557823129, rmsDB: -18.07800029930726),
        StarterTrackFacts(id: "1458069", durationSeconds: 276.44, bpm: 71.01626235448764, beatPeriod: 0.8448769058064698, beatPhase: 0.6965986394557823, rmsDB: -13.145948629186053),
        StarterTrackFacts(id: "1629934", durationSeconds: 209.45455782312925, bpm: 73.90676089374533, beatPeriod: 0.8118337114822435, beatPhase: 0.6355857876718962, rmsDB: -12.206776331809326),
        StarterTrackFacts(id: "501673", durationSeconds: 329.05727891156465, bpm: 74.67632527397049, beatPeriod: 0.8034674949506904, beatPhase: 0.6733786848072563, rmsDB: -15.765069366764152),
        StarterTrackFacts(id: "1406396", durationSeconds: 239.75106575963719, bpm: 75.00278446921679, beatPeriod: 0.7999703000976671, beatPhase: 0.05160196112002724, rmsDB: -14.058149580535195),
        StarterTrackFacts(id: "946", durationSeconds: 241.6873015873016, bpm: 109.9731308178132, beatPeriod: 0.5455878136214827, beatPhase: 0.3374194279735494, rmsDB: -14.20928256941221),
        StarterTrackFacts(id: "20237", durationSeconds: 263.99809523809523, bpm: 109.9866534303118, beatPeriod: 0.5455207348227606, beatPhase: 0.0349781313903913, rmsDB: -12.340783037505943),
        StarterTrackFacts(id: "7475", durationSeconds: 402.0142403628118, bpm: 109.99581287515174, beatPeriod: 0.5454753088474527, beatPhase: 0.3022466612166592, rmsDB: -17.731080173593373),
        StarterTrackFacts(id: "1555047", durationSeconds: 296.7273015873016, bpm: 110.00469662075537, beatPeriod: 0.5454312574203252, beatPhase: 0.1180011878029319, rmsDB: -11.338004077020209),
        StarterTrackFacts(id: "1353514", durationSeconds: 193.92857142857142, bpm: 112.01692340095039, beatPeriod: 0.5356333505539836, beatPhase: 0.30303785414899087, rmsDB: -12.008305213960139),
        StarterTrackFacts(id: "296235", durationSeconds: 304.56303854875284, bpm: 113.32923738870913, beatPeriod: 0.5294308987027361, beatPhase: 0.2136076500500984, rmsDB: -16.311621998458968),
        StarterTrackFacts(id: "1204663", durationSeconds: 250.33278911564625, bpm: 80.0008048742245, beatPeriod: 0.7499924543800612, beatPhase: 0.6733786848072563, rmsDB: -11.906597422194952),
        StarterTrackFacts(id: "1585553", durationSeconds: 175.0477551020408, bpm: 80.0046118159518, beatPeriod: 0.7499567667177511, beatPhase: 0.06965986394557823, rmsDB: -12.910355717465903),
        StarterTrackFacts(id: "1246367", durationSeconds: 183.7439909297052, bpm: 80.21383759995007, beatPeriod: 0.7480006167918009, beatPhase: 0.46439909297052157, rmsDB: -21.362147535162674),
        StarterTrackFacts(id: "337997", durationSeconds: 251.16299319727892, bpm: 82.17130077313021, beatPeriod: 0.7301819423019263, beatPhase: 0.44367239657528557, rmsDB: -11.602148530581864),
        StarterTrackFacts(id: "1204670", durationSeconds: 229.94721088435375, bpm: 83.02554484538823, beatPeriod: 0.72266915094304, beatPhase: 0.6501587301587302, rmsDB: -11.424079291750724),
        StarterTrackFacts(id: "1337398", durationSeconds: 267.92326530612246, bpm: 84.99518160368753, beatPeriod: 0.7059223695734406, beatPhase: 0.6965986394557823, rmsDB: -18.34921611371929),
        StarterTrackFacts(id: "81744", durationSeconds: 275.4545578231293, bpm: 129.54995616225187, beatPeriod: 0.4631418008729727, beatPhase: 0.2089795918367347, rmsDB: -11.675646830567633),
        StarterTrackFacts(id: "951", durationSeconds: 199.60027210884354, bpm: 129.8759531242172, beatPeriod: 0.46197928528473803, beatPhase: 0.03531899307744374, rmsDB: -13.18763987858709),
        StarterTrackFacts(id: "2016794", durationSeconds: 221.5387755102041, bpm: 129.9820367452652, beatPeriod: 0.4616022452209005, beatPhase: 0.07271804149014793, rmsDB: -10.928237730989462),
        StarterTrackFacts(id: "222565", durationSeconds: 287.7643537414966, bpm: 129.99985851935958, beatPeriod: 0.4615389638371399, beatPhase: 0.049300038430433846, rmsDB: -12.620933081603297),
        StarterTrackFacts(id: "1059819", durationSeconds: 181.05532879818594, bpm: 130.04710623536369, beatPeriod: 0.46137128104496195, beatPhase: 0.05249553314817135, rmsDB: -10.535882082769579),
        StarterTrackFacts(id: "375191", durationSeconds: 218.7101133786848, bpm: 130.07329757028324, beatPeriod: 0.46127838011933125, beatPhase: 0.012482851404761242, rmsDB: -12.25642041706192),
        StarterTrackFacts(id: "29872", durationSeconds: 188.8041723356009, bpm: 60.0, beatPeriod: 1.0, beatPhase: 0.2786394557823129, rmsDB: -16.599880439062776),
        StarterTrackFacts(id: "957463", durationSeconds: 197.84054421768707, bpm: 60.0, beatPeriod: 1.0, beatPhase: 0.8126984126984127, rmsDB: -17.562439326546517),
        StarterTrackFacts(id: "1589557", durationSeconds: 295.91510204081635, bpm: 62.54001791247541, beatPeriod: 0.9593857181807949, beatPhase: 0.545684151197309, rmsDB: -14.468929696278288),
        StarterTrackFacts(id: "1393688", durationSeconds: 240.03845804988663, bpm: 63.84322115357926, beatPeriod: 0.9398022047738769, beatPhase: 0.9017489483697254, rmsDB: -7.535134032575394),
        StarterTrackFacts(id: "878019", durationSeconds: 343.2316553287982, bpm: 64.61149180882369, beatPeriod: 0.9286273744852008, beatPhase: 0.3949100404807856, rmsDB: -16.76429732712874),
        StarterTrackFacts(id: "398173", durationSeconds: 326.841179138322, bpm: 64.97185581358569, beatPeriod: 0.9234767769624633, beatPhase: 0.8857453668883636, rmsDB: -18.225940010271387),
    ]
    static let byID: [String: StarterTrackFacts] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
