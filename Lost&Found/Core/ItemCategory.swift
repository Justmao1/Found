import Foundation

/// A local presentation category inferred only from an item's primary recognition tag.
public enum ItemCategory: String, CaseIterable, Sendable {
    case backpack, bag, suitcase, wallet, identityCard, bankCard, keys, keychain
    case bottle, cup, umbrella, glasses, phone, phoneCase, tablet, laptop, keyboard
    case headphones, earbuds, charger, cable, powerBank, watch, camera, book, notebook, pen
    case clothing, clothingAccessory, jacket, shoes, hat, jewelry, ball, basketball, tennisBall, toy, tool, other

    public var symbolName: String {
        switch self {
        case .backpack: "backpack.fill"
        case .bag: "bag.fill"
        case .suitcase: "suitcase.rolling.fill"
        case .wallet: "wallet.pass.fill"
        case .identityCard: "person.text.rectangle"
        case .bankCard: "creditcard.fill"
        case .keys: "key.fill"
        case .keychain: "key.horizontal.fill"
        case .bottle: "waterbottle.fill"
        case .cup: "cup.and.saucer.fill"
        case .umbrella: "umbrella.fill"
        case .glasses: "eyeglasses"
        case .phone: "iphone"
        case .phoneCase: "rectangle.portrait"
        case .tablet: "ipad"
        case .laptop: "laptopcomputer"
        case .keyboard: "keyboard"
        case .headphones: "headphones"
        case .earbuds: "earbuds"
        case .charger: "powerplug.fill"
        case .cable: "cable.connector"
        case .powerBank: "battery.100percent"
        case .watch: "applewatch"
        case .camera: "camera.fill"
        case .book: "book.closed.fill"
        case .notebook: "note.text"
        case .pen: "pencil"
        case .clothing: "tshirt.fill"
        case .clothingAccessory: "hanger"
        case .jacket: "jacket.fill"
        case .shoes: "shoeprints.fill"
        case .hat: "hat.cap.fill"
        case .jewelry: "ring"
        case .ball: "soccerball"
        case .basketball: "basketball.fill"
        case .tennisBall: "tennisball.fill"
        case .toy: "teddybear.fill"
        case .tool: "wrench.and.screwdriver.fill"
        case .other: "shippingbox"
        }
    }

    public static func matching(_ primaryTag: String?) -> ItemCategory {
        guard let primaryTag else { return .other }
        let tag = normalized(primaryTag)
        guard !tag.isEmpty else { return .other }

        for entry in aliases {
            if tag == entry.name { return entry.category }
            guard tag.hasSuffix(" " + entry.name) else { continue }
            let prefix = tag.dropLast(entry.name.count + 1)
            // Allow short category qualifiers, never a sentence that merely mentions an item.
            let words = prefix.split(separator: " ")
            if !words.isEmpty && words.count <= 4 && words.allSatisfy({ qualifiers.contains(String($0)) }) {
                return entry.category
            }
        }
        return .other
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[-‐‑‒–—_]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let qualifiers: Set<String> = [
        "black", "white", "grey", "gray", "red", "orange", "yellow", "green", "blue",
        "purple", "pink", "brown", "beige", "silver", "gold", "golden", "clear", "transparent",
        "dark", "light", "navy", "small", "large", "mini", "long", "short", "round", "square",
        "leather", "canvas", "fabric", "cloth", "plastic", "metal", "steel", "stainless", "glass",
        "ceramic", "wooden", "silicone", "rubber", "insulated", "thermal", "reusable", "disposable",
        "wireless", "wired", "bluetooth", "digital", "analog", "analogue", "smart", "portable",
        "folding", "foldable", "compact", "waterproof", "water", "resistant", "travel", "school",
        "sports", "sport", "running", "reading", "prescription", "polarized", "protective", "apple"
    ]

    private struct Alias: Sendable {
        let name: String
        let category: ItemCategory
    }

    /// More specific aliases win, e.g. "phone case" before "phone" and "notebook computer" before "notebook".
    private static let aliases: [Alias] = {
        var result: [Alias] = []
        for (category, names) in aliasGroups {
            for name in names {
                result.append(Alias(name: normalized(name), category: category))
            }
        }
        result.sort {
            if $0.name.count == $1.name.count { return $0.name < $1.name }
            return $0.name.count > $1.name.count
        }
        return result
    }()

    private static let aliasGroups: [(ItemCategory, [String])] = [
            (.backpack, ["backpack", "backpacks", "rucksack", "rucksacks", "knapsack", "schoolbag", "school bag", "背包", "双肩包", "书包"]),
            (.bag, ["bag", "bags", "handbag", "handbags", "tote", "tote bag", "shoulder bag", "crossbody bag", "messenger bag", "duffel bag", "duffle bag", "包", "手提包", "单肩包", "帆布包"]),
            (.suitcase, ["suitcase", "suitcases", "luggage", "carry on", "carry on bag", "rolling suitcase", "行李箱", "拉杆箱"]),
            (.wallet, ["wallet", "wallets", "purse", "purses", "coin purse", "card holder", "cardholder", "钱包", "零钱包", "卡包"]),
            (.identityCard, ["id", "id card", "identity card", "identification card", "student id", "student card", "student id card", "driver's license", "driving licence", "passport", "passports", "badge", "name badge", "身份证", "学生证", "护照", "证件", "工牌"]),
            (.bankCard, ["credit card", "credit cards", "debit card", "debit cards", "bank card", "bank cards", "银行卡", "信用卡", "借记卡"]),
            (.keys, ["key", "keys", "house key", "house keys", "car key", "car keys", "key fob", "set of keys", "钥匙", "车钥匙"]),
            (.keychain, ["keychain", "keychains", "key chain", "key chains", "keyring", "keyrings", "key ring", "key rings", "钥匙扣", "钥匙圈"]),
            (.bottle, ["bottle", "bottles", "water bottle", "water bottles", "thermos", "thermos flask", "flask", "水瓶", "水壶", "保温瓶", "保温杯"]),
            (.cup, ["cup", "cups", "mug", "mugs", "coffee mug", "coffee cup", "tumbler", "tumblers", "travel mug", "杯子", "水杯", "马克杯", "咖啡杯"]),
            (.umbrella, ["umbrella", "umbrellas", "parasol", "雨伞", "伞", "遮阳伞"]),
            (.glasses, ["glasses", "eyeglasses", "spectacles", "sunglasses", "reading glasses", "眼镜", "墨镜", "太阳镜"]),
            (.phone, ["phone", "phones", "mobile phone", "mobile phones", "cell phone", "cellphone", "smartphone", "smartphones", "iphone", "手机"]),
            (.phoneCase, ["phone case", "phone cases", "mobile phone case", "cell phone case", "iphone case", "smartphone case", "phone cover", "手机壳", "手机套"]),
            (.tablet, ["tablet", "tablets", "tablet computer", "ipad", "ipads", "平板", "平板电脑"]),
            (.laptop, ["laptop", "laptops", "laptop computer", "notebook computer", "macbook", "笔记本电脑", "电脑"]),
            (.keyboard, ["keyboard", "keyboards", "computer keyboard", "键盘"]),
            (.headphones, ["headphones", "headphone", "headset", "headsets", "耳机", "头戴式耳机"]),
            (.earbuds, ["earphones", "earphone", "earbuds", "earbud", "airpods", "earbud case", "airpods case", "耳塞", "入耳式耳机", "耳机盒"]),
            (.charger, ["charger", "chargers", "phone charger", "laptop charger", "power adapter", "power adaptor", "charging adapter", "charging brick", "充电器", "电源适配器", "充电头"]),
            (.cable, ["cable", "cables", "charging cable", "charging cables", "usb cable", "usb c cable", "lightning cable", "power cord", "数据线", "充电线", "电源线"]),
            (.powerBank, ["power bank", "power banks", "powerbank", "powerbanks", "portable charger", "battery pack", "external battery", "充电宝", "移动电源"]),
            (.watch, ["watch", "watches", "wristwatch", "smartwatch", "smart watch", "apple watch", "手表", "智能手表"]),
            (.camera, ["camera", "cameras", "digital camera", "action camera", "相机", "照相机"]),
            (.book, ["book", "books", "textbook", "textbooks", "novel", "novels", "书", "书籍", "课本"]),
            (.notebook, ["notebook", "notebooks", "notepad", "notepads", "journal", "diary", "planner", "sketchbook", "笔记本", "记事本", "日记本"]),
            (.pen, ["pen", "pens", "pencil", "pencils", "marker", "markers", "fountain pen", "ballpoint pen", "stylus", "apple pencil", "笔", "钢笔", "铅笔", "圆珠笔", "触控笔"]),
            (.clothing, ["clothing", "clothes", "shirt", "shirts", "t shirt", "tshirt", "sweater", "jumper", "hoodie", "trousers", "pants", "shorts", "dress", "skirt", "衣服", "衬衫", "短袖", "毛衣", "裤子", "裙子"]),
            (.clothingAccessory, ["gloves", "glove", "scarf", "scarves", "belt", "belts", "tie", "ties", "手套", "围巾", "腰带", "领带"]),
            (.jacket, ["jacket", "jackets", "coat", "coats", "raincoat", "overcoat", "外套", "夹克", "大衣", "雨衣"]),
            (.shoes, ["shoe", "shoes", "sneaker", "sneakers", "trainer", "trainers", "boot", "boots", "sandal", "sandals", "slipper", "slippers", "鞋", "鞋子", "运动鞋", "靴子", "拖鞋"]),
            (.hat, ["hat", "hats", "cap", "caps", "baseball cap", "beanie", "帽子", "棒球帽", "毛线帽"]),
            (.jewelry, ["jewelry", "jewellery", "ring", "rings", "earring", "earrings", "necklace", "necklaces", "bracelet", "bracelets", "pendant", "首饰", "珠宝", "戒指", "项链", "手链", "耳环"]),
            (.ball, ["ball", "balls", "soccer ball", "football", "volleyball", "球", "足球", "排球"]),
            (.basketball, ["basketball", "basketballs", "basket ball", "篮球"]),
            (.tennisBall, ["tennis ball", "tennis balls", "网球"]),
            (.toy, ["toy", "toys", "teddy bear", "stuffed animal", "plush toy", "plushie", "doll", "玩具", "玩偶", "毛绒玩具"]),
            (.tool, ["tool", "tools", "screwdriver", "wrench", "spanner", "pliers", "hammer", "multitool", "multi tool", "bottle opener", "工具", "螺丝刀", "扳手", "钳子", "锤子", "开瓶器"])
    ]
}
