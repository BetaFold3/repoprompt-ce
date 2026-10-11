//
//  DebouncedHoverModifier.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-02.
//

import Combine
import SwiftUI

struct DebouncedOnHoverModifier: ViewModifier {
    let delay: TimeInterval
    let action: (Bool) -> Void

    // A subject to stream hover events.
    @State private var hoverSubject = PassthroughSubject<Bool, Never>()
    @State private var cancellable: AnyCancellable?

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Debounce hover events and then call the provided action.
                cancellable = hoverSubject
                    .debounce(for: .seconds(delay), scheduler: RunLoop.main)
                    .sink { value in
                        action(value)
                    }
            }
            .onDisappear {
                cancellable?.cancel()
            }
            // Send hover events into the subject.
            .onHover { hovering in
                hoverSubject.send(hovering)
            }
    }
}

extension View {
    func debouncedOnHover(delay: TimeInterval = 0.1, action: @escaping (Bool) -> Void) -> some View {
        modifier(DebouncedOnHoverModifier(delay: delay, action: action))
    }
}
