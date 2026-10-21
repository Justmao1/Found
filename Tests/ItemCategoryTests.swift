import XCTest
@testable import LostFoundCore

final class ItemCategoryTests: XCTestCase {
    func testNormalizesCaseWhitespaceAndHyphenVariants() {
        XCTAssertEqual(ItemCategory.matching("  WATER\n  BOTTLE  "), .bottle)
        XCTAssertEqual(ItemCategory.matching("BLUE\tBACKPACK"), .backpack)
        XCTAssertEqual(ItemCategory.matching("  USB‑C   CABLE "), .cable)
        XCTAssertEqual(ItemCategory.matching("T-SHIRT"), .clothing)
        XCTAssertEqual(ItemCategory.matching("ｐｈｏｎｅ"), .phone)
    }

    func testCommonSynonymsAndPlurals() {
        for tag in ["backpacks", "rucksack", "knapsack", "school bag"] {
            XCTAssertEqual(ItemCategory.matching(tag), .backpack, tag)
        }
        for tag in ["earbuds", "earphones", "AirPods"] {
            XCTAssertEqual(ItemCategory.matching(tag), .earbuds, tag)
        }
        XCTAssertEqual(ItemCategory.matching("headsets"), .headphones)
        XCTAssertEqual(ItemCategory.matching("gloves"), .clothingAccessory)
        XCTAssertEqual(ItemCategory.matching("scarves"), .clothingAccessory)
        XCTAssertEqual(ItemCategory.matching("spectacles"), .glasses)
        XCTAssertEqual(ItemCategory.matching("purses"), .wallet)
        XCTAssertEqual(ItemCategory.matching("trainers"), .shoes)
        XCTAssertEqual(ItemCategory.matching("jewellery"), .jewelry)
    }

    func testSpecificCompoundCategoriesWin() {
        XCTAssertEqual(ItemCategory.matching("phone case"), .phoneCase)
        XCTAssertEqual(ItemCategory.matching("blue silicone phone case"), .phoneCase)
        XCTAssertEqual(ItemCategory.matching("phone charger"), .charger)
        XCTAssertEqual(ItemCategory.matching("portable charger"), .powerBank)
        XCTAssertEqual(ItemCategory.matching("notebook computer"), .laptop)
        XCTAssertEqual(ItemCategory.matching("notebook"), .notebook)
        XCTAssertEqual(ItemCategory.matching("key ring"), .keychain)
        XCTAssertEqual(ItemCategory.matching("ring"), .jewelry)
        XCTAssertEqual(ItemCategory.matching("bottle opener"), .tool)
        XCTAssertEqual(ItemCategory.matching("keyboard"), .keyboard)
    }

    func testRecognizesShortQualifiedCategories() {
        XCTAssertEqual(ItemCategory.matching("blue backpack"), .backpack)
        XCTAssertEqual(ItemCategory.matching("insulated water bottle"), .bottle)
        XCTAssertEqual(ItemCategory.matching("stainless steel water bottle"), .bottle)
        XCTAssertEqual(ItemCategory.matching("dark brown leather wallet"), .wallet)
        XCTAssertEqual(ItemCategory.matching("wireless headphones"), .headphones)
        XCTAssertEqual(ItemCategory.matching("small folding umbrella"), .umbrella)
    }

    func testDoesNotMistakeSubstringsOrSentencesForPrimaryCategory() {
        for tag in ["monkey", "cupboard", "keyhole", "phonecaseunknown", "watch strap",
                    "bottle cap", "headphone stand", "phone case packaging", "a photo of a phone",
                    "bag of keys", "not a phone", "I lost my blue backpack", "red, blue, keys",
                    "phone / wallet", "red blue green yellow black backpack"] {
            XCTAssertEqual(ItemCategory.matching(tag), .other, tag)
        }
    }

    func testMissingOrUnknownTagsUseNeutralFallback() {
        XCTAssertEqual(ItemCategory.matching(nil), .other)
        for tag in ["", " \n\t ", "unknown", "miscellaneous", "red", "metal", "unidentified object", "🧳"] {
            XCTAssertEqual(ItemCategory.matching(tag), .other, tag)
        }
        XCTAssertEqual(ItemCategory.other.symbolName, "shippingbox")
    }

    func testChineseCategoriesRemainDistinct() {
        XCTAssertEqual(ItemCategory.matching("双肩包"), .backpack)
        XCTAssertEqual(ItemCategory.matching("保温杯"), .bottle)
        XCTAssertEqual(ItemCategory.matching("手机"), .phone)
        XCTAssertEqual(ItemCategory.matching("手机壳"), .phoneCase)
        XCTAssertEqual(ItemCategory.matching("笔记本"), .notebook)
        XCTAssertEqual(ItemCategory.matching("笔记本电脑"), .laptop)
        XCTAssertEqual(ItemCategory.matching("充电宝"), .powerBank)
        XCTAssertEqual(ItemCategory.matching("钥匙扣"), .keychain)
        XCTAssertEqual(ItemCategory.matching("入耳式耳机"), .earbuds)
        XCTAssertEqual(ItemCategory.matching("围巾"), .clothingAccessory)
        XCTAssertEqual(ItemCategory.matching("篮球"), .basketball)
        XCTAssertEqual(ItemCategory.matching("网球"), .tennisBall)
    }

    func testEveryCategoryHasARecognizableRepresentativeAndSymbol() {
        let representatives: [(String, ItemCategory)] = [
            ("backpack", .backpack), ("tote bag", .bag), ("luggage", .suitcase), ("wallet", .wallet),
            ("student ID card", .identityCard), ("credit card", .bankCard), ("house keys", .keys),
            ("keychain", .keychain), ("thermos", .bottle), ("mug", .cup), ("umbrella", .umbrella),
            ("sunglasses", .glasses), ("smartphone", .phone), ("phone cover", .phoneCase),
            ("iPad", .tablet), ("MacBook", .laptop), ("keyboard", .keyboard), ("headset", .headphones),
            ("earbuds", .earbuds),
            ("power adapter", .charger), ("USB cable", .cable), ("battery pack", .powerBank),
            ("wristwatch", .watch), ("camera", .camera), ("textbook", .book), ("journal", .notebook),
            ("stylus", .pen), ("sweater", .clothing), ("scarf", .clothingAccessory), ("coat", .jacket), ("sneakers", .shoes),
            ("beanie", .hat), ("necklace", .jewelry), ("football", .ball), ("basketball", .basketball),
            ("tennis balls", .tennisBall), ("teddy bear", .toy),
            ("screwdriver", .tool), ("unrecognized category", .other)
        ]
        XCTAssertEqual(Set(representatives.map(\.1)), Set(ItemCategory.allCases))
        for (tag, category) in representatives {
            XCTAssertEqual(ItemCategory.matching(tag), category, tag)
            XCTAssertFalse(category.symbolName.isEmpty, tag)
        }
    }
}
