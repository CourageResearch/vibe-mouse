enum InputEventMarker {
    // Shared by keyboard, link clicks, and auto-scroll so generated input is never
    // remapped a second time by our own event tap.
    static let synthetic: Int64 = 0x564D0A17
}
