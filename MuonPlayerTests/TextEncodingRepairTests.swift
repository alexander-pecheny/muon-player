import Testing
@testable import MuonPlayer

/// CP1251 tags misread as Latin-1 must be recovered; everything else must be
/// left exactly as it is — the transform is destructive when misapplied.
@Suite("CP1251 mojibake repair")
struct TextEncodingRepairTests {

    @Test("Recovers Cyrillic mojibaked by a Latin-1 misread", arguments: [
        ("Ñåñòðà Ñàøè", "Сестра Саши"),
        ("30 äíåé ôåâðàëÿ", "30 дней февраля"),
        ("Ìíå òàê ñòðàøíî çà òåáÿ", "Мне так страшно за тебя"),
        ("Òâîÿ ñåñòðà Ñàøè", "Твоя сестра Саши"),
        ("Êàæäûé èç íàñ", "Каждый из нас"),
        // `ч` mojibakes to `÷`, a division sign rather than a letter.
        ("Áîí÷ Áðó Áîí÷", "Бонч Бру Бонч"),
        ("Ñ.Ä. Äîâëàòîâ. Êðàòêàÿ Áèîãðàôè÷åñêàÿ Ñïðàâêà",
         "С.Д. Довлатов. Краткая Биографическая Справка"),
    ])
    func repairsMojibake(input: String, expected: String) {
        #expect(TextEncodingRepair.repair(input) == expected)
    }

    /// Cyrillic runs stay recognisable even when ASCII words outnumber them.
    @Test("Repairs Cyrillic diluted by ASCII", arguments: [
        ("Áîí÷ Áðó Áîí÷ @ VIP PARTY", "Бонч Бру Бонч @ VIP PARTY"),
        ("Áîí÷ Áðó Áîí÷ @ Ãîâîðÿò (Ñá. Îì-Ðàäèî)", "Бонч Бру Бонч @ Говорят (Сб. Ом-Радио)"),
    ])
    func repairsDilutedMojibake(input: String, expected: String) {
        #expect(TextEncodingRepair.repair(input) == expected)
    }

    @Test("Leaves text that is already correct alone", arguments: [
        "Сестра Саши",              // real Cyrillic (scalars above U+00FF)
        "Bohemian Rhapsody",        // pure ASCII
        "Motörhead",                // Latin with an umlaut — would become "Motцrhead"
        "Café",                     // single accent
        "Björk",
        "Sigur Rós",
        "ÅÄÖ",                      // all-caps accents: bytes all below 0xE0
        "",
        "東京",                      // non-Latin, non-Cyrillic
        "Tiësto",                   // isolated accents never form a run of three
        "Zoë & Naïve Café",
        "Þórir",
        "AC/DC — Live 1979",
    ])
    func leavesGoodTextAlone(input: String) {
        #expect(TextEncodingRepair.repair(input) == input)
    }

    @Test("Repairs Cyrillic mixed with ASCII")
    func mixedWithAscii() {
        #expect(TextEncodingRepair.repair("Ñåñòðà Ñàøè (Remix)") == "Сестра Саши (Remix)")
    }
}
