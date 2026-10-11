//
//  ResizeHandle.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-08-10.
//

import SwiftUI

struct ResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @State private var isHovering = false
    @GestureState private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(isHovering || isDragging ? 0.7 : 0.5))
            .frame(height: 8)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture()
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        height = min(maxHeight, max(minHeight, height + value.translation.height))
                    }
            )
    }
}

struct BottomResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @State private var isHovering = false
    @GestureState private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(isHovering || isDragging ? 0.7 : 0.5))
            .frame(height: 8)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        height = min(maxHeight, max(minHeight, height - value.translation.height))
                    }
            )
    }
}
