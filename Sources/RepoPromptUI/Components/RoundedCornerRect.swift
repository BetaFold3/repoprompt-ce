//
//  RoundedCornerRect.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-08-18.
//

import AppKit
import SwiftUI

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int

    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)

    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let topLeft = corners.contains(.topLeft)
        let topRight = corners.contains(.topRight)
        let bottomLeft = corners.contains(.bottomLeft)
        let bottomRight = corners.contains(.bottomRight)

        let width = rect.size.width
        let height = rect.size.height

        path.move(to: CGPoint(x: topLeft ? radius : 0, y: 0))
        path.addLine(to: CGPoint(x: width - (topRight ? radius : 0), y: 0))
        if topRight {
            path.addArc(center: CGPoint(x: width - radius, y: radius), radius: radius, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: width, y: height - (bottomRight ? radius : 0)))
        if bottomRight {
            path.addArc(center: CGPoint(x: width - radius, y: height - radius), radius: radius, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: bottomLeft ? radius : 0, y: height))
        if bottomLeft {
            path.addArc(center: CGPoint(x: radius, y: height - radius), radius: radius, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: 0, y: topLeft ? radius : 0))
        if topLeft {
            path.addArc(center: CGPoint(x: radius, y: radius), radius: radius, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        }
        path.closeSubpath()

        return path
    }
}

/// New shape specifically for non-selected tab borders (omits bottom line)
struct NonSelectedTabBorder: Shape {
    var radius: CGFloat = 16
    var corners: RectCorner = [.topLeft, .topRight]

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let topLeft = corners.contains(.topLeft)
        let topRight = corners.contains(.topRight)

        let width = rect.size.width
        let height = rect.size.height

        // Start from bottom-left corner (but don't draw bottom line)
        path.move(to: CGPoint(x: 0, y: height))

        // Line up left side
        path.addLine(to: CGPoint(x: 0, y: topLeft ? radius : 0))

        // Top-left corner arc
        if topLeft {
            path.addArc(center: CGPoint(x: radius, y: radius), radius: radius, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        }

        // Top line
        path.addLine(to: CGPoint(x: width - (topRight ? radius : 0), y: 0))

        // Top-right corner arc
        if topRight {
            path.addArc(center: CGPoint(x: width - radius, y: radius), radius: radius, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
        }

        // Line down right side
        path.addLine(to: CGPoint(x: width, y: height))

        // Intentionally do not close the path or draw the bottom line

        return path
    }
}
