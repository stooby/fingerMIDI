//
//  fingerMIDI.swift
//  fingerMIDI
//
//  Created by Scott Tooby on 5/22/26.
//

import SwiftUI

@main
struct fingerMIDIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Make the window honor ContentView's .frame limits: fixed 490-pt height and a
        // 1126-pt minimum width that can grow but not shrink. .contentSize (not .contentMinSize)
        // is required so the max-height constraint pins the height instead of only setting a floor.
        .windowResizability(.contentSize)
    }
}
