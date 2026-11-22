//
//  StatusBarCharts.swift
//  CPU Guard
//

import AppKit

/// What is shown next to the icon in the menu bar.
enum StatusDisplayMode: String, CaseIterable {
    case none, values, charts, activeApp

    var title: String {
        switch self {
        case .none: return "None"
        case .values: return "CPU & Memory Values"
        case .charts: return "CPU & Memory Charts"
        case .activeApp: return "Active App CPU & Memory"
        }
    }

    private static let defaultsKey = "statusDisplayMode"

    static func load() -> StatusDisplayMode {
        StatusDisplayMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .values
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct Candle {
    var open: Double
    var high: Double
    var low: Double
    var close: Double
}

/// Rolling OHLC series: each candle aggregates `samplesPerCandle` consecutive samples.
struct CandleSeries {
    let samplesPerCandle: Int
    let maxCandles: Int
    private(set) var candles: [Candle] = []
    private var samplesInLast = 0

    init(samplesPerCandle: Int, maxCandles: Int) {
        self.samplesPerCandle = samplesPerCandle
        self.maxCandles = maxCandles
    }

    mutating func add(_ value: Double) {
        if candles.isEmpty || samplesInLast >= samplesPerCandle {
            candles.append(Candle(open: value, high: value, low: value, close: value))
            samplesInLast = 1
            if candles.count > maxCandles {
                candles.removeFirst(candles.count - maxCandles)
            }
        } else {
            candles[candles.count - 1].high = max(candles[candles.count - 1].high, value)
            candles[candles.count - 1].low = min(candles[candles.count - 1].low, value)
            candles[candles.count - 1].close = value
            samplesInLast += 1
        }
    }
}

enum CandleChart {
    /// Draws a 0-100 candlestick chart. Candles whose peak reaches `highThreshold` are red.
    static func draw(_ series: CandleSeries, in rect: NSRect, color: NSColor, highThreshold: Double) {
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        color.withAlphaComponent(0.35).setStroke()
        frame.lineWidth = 1
        frame.stroke()

        let inner = rect.insetBy(dx: 2, dy: 2)
        let slot = inner.width / CGFloat(series.maxCandles)
        let bodyWidth = max(slot - 0.6, 0.8)
        // Newest candle sits at the right edge; older ones to its left.
        let offset = CGFloat(series.maxCandles - series.candles.count) * slot

        func y(_ value: Double) -> CGFloat {
            inner.minY + CGFloat(max(0, min(value, 100)) / 100) * inner.height
        }

        for (i, candle) in series.candles.enumerated() {
            let x = inner.minX + offset + CGFloat(i) * slot + slot / 2
            let tint: NSColor = candle.high >= highThreshold ? .systemRed : color

            tint.setStroke()
            let wick = NSBezierPath()
            wick.lineWidth = 0.6
            wick.move(to: NSPoint(x: x, y: y(candle.low)))
            wick.line(to: NSPoint(x: x, y: y(candle.high)))
            wick.stroke()

            let bodyBottom = y(min(candle.open, candle.close))
            let bodyHeight = max(y(max(candle.open, candle.close)) - bodyBottom, 1)
            tint.setFill()
            NSRect(x: x - bodyWidth / 2, y: bodyBottom, width: bodyWidth, height: bodyHeight).fill()
        }
    }
}
