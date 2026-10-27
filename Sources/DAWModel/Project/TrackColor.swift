/// An sRGB color, each component 0…1.
public struct TrackColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let gray = TrackColor(red: 0.5, green: 0.5, blue: 0.5)
}
