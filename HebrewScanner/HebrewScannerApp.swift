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

    @FocusedValue(\.exportAction) var exportAction

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("ייצא למסמך…") {
                    exportAction?()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exportAction == nil)
            }
        }
    }
}
