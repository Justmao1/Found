import UIKit
import XCTest
@testable import Lost_Found

final class ItemCategorySymbolTests: XCTestCase {
    func testEveryCatalogSymbolExistsInTheInstalledSystem() {
        for category in ItemCategory.allCases {
            XCTAssertNotNil(UIImage(systemName: category.symbolName),
                            "Missing SF Symbol for \(category.rawValue): \(category.symbolName)")
        }
    }
}
