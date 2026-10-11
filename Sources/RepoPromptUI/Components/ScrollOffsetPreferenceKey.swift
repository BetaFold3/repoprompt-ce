//
//  ScrollOffsetPreferenceKey.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-07-19.
//

import SwiftUI

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}
