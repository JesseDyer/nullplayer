// Build: swiftc -O -o rclick rclick.swift
// rclick <x> <y>: post a right mouse down/up at a global top-left point
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(80_000)
for t in [CGEventType.rightMouseDown, .rightMouseUp] {
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .right)!
    e.setIntegerValueField(.mouseEventClickState, value: 1)
    e.post(tap: .cghidEventTap); usleep(60_000)
}
