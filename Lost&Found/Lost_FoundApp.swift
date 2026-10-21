//
//  Lost_FoundApp.swift
//  Lost&Found
//
//  Created by Zhekai Mao on 2026/10/20.
//

import SwiftUI

@main
struct Lost_FoundApp: App {
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
