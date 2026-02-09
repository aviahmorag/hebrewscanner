//
//  HebrewScannerApp.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import SwiftUI

@main
struct HebrewScannerApp: App {
    init() {
        // Preload DictaBERT in the background so it's ready when OCR finishes
        Task.detached(priority: .utility) {
            await HebrewLanguageModel.shared.loadModel()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
