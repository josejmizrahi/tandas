import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("ResourceTypeChrome")
struct ResourceTypeChromeTests {
    @Test("every ResourceType resolves to a non-empty symbol + label")
    func everyTypeHasChrome() {
        for type in ResourceType.allCases {
            let chrome = ResourceTypeChrome.resolve(type)
            #expect(!chrome.symbol.isEmpty, "symbol empty for \(type)")
            #expect(!chrome.labelKey.isEmpty, "labelKey empty for \(type)")
        }
    }

    @Test("event resolves to calendar symbol")
    func eventChrome() {
        let c = ResourceTypeChrome.resolve(.event)
        #expect(c.symbol == "calendar")
        #expect(c.labelKey == "resource.type.event")
    }

    @Test("fund resolves to banknote symbol")
    func fundChrome() {
        #expect(ResourceTypeChrome.resolve(.fund).symbol == "banknote")
    }

    @Test("asset resolves to key.fill symbol")
    func assetChrome() {
        #expect(ResourceTypeChrome.resolve(.asset).symbol == "key.fill")
    }

    @Test("space resolves to mappin.and.ellipse symbol")
    func spaceChrome() {
        #expect(ResourceTypeChrome.resolve(.space).symbol == "mappin.and.ellipse")
    }

    @Test("slot resolves to ticket symbol")
    func slotChrome() {
        #expect(ResourceTypeChrome.resolve(.slot).symbol == "ticket")
    }

    @Test("right resolves to person.badge.key.fill symbol")
    func rightChrome() {
        #expect(ResourceTypeChrome.resolve(.right).symbol == "person.badge.key.fill")
    }
}
