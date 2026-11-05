import XCTest
@testable import WhiskerFlowCore

final class DictatedNumberFormatterTests: XCTestCase {
    func testFormatsSterlingWithExactPence() {
        let cases = [
            ("451 pounds and fifty one pence", "£451.51"),
            ("four hundred and fifty-one pounds and fifty-one pence", "£451.51"),
            ("four hundred and 51 pounds and 51 pence", "£451.51"),
            ("four hundred fifty one pounds fifty one", "£451.51"),
            ("seventeen pounds fifty", "£17.50"),
            ("75 pounds", "£75"),
            ("one pound and five pence", "£1.05"),
            ("one pound and zero pence", "£1.00"),
            ("fifty-one pence", "£0.51"),
            ("a penny", "£0.01"),
            ("one hundred and fifty-one pence", "£1.51"),
            ("two thousand three hundred and four pounds and nine pence", "£2,304.09"),
            ("451.51 pounds", "£451.51"),
            ("four point five pounds", "£4.50"),
            ("four point fifty-one pounds", "£4.51"),
            ("minus four pounds and five pence", "-£4.05"),
            ("-2 million and five pounds", "-£2,000,005"),
            ("two point five million pounds", "£2,500,000"),
            ("2.5 million pounds", "£2,500,000"),
            ("£451.51", "£451.51"),
            ("£1,234.50", "£1,234.50"),
            ("GBP 451.51", "£451.51")
        ]
        for (spoken, expected) in cases {
            XCTAssertEqual(DictatedNumberFormatter.format(spoken), expected, spoken)
            XCTAssertEqual(DictatedNumberFormatter.format(expected), expected, "Repeated formatting changed \(expected)")
        }
    }

    func testRendersCardinalQuantitiesAndDecimalsAsDigits() {
        for (spoken, expected) in [
            ("We need twenty-one copies and three boxes.", "We need 21 copies and 3 boxes."),
            ("There are one hundred and fifty-one people.", "There are 151 people."),
            ("The total is two million three hundred thousand and five.", "The total is 2300005."),
            ("It is one point zero five metres.", "It is 1.05 metres."),
            ("The temperature is minus ten degrees.", "The temperature is -10 degrees."),
            ("Use 2.5 million copies.", "Use 2500000 copies."),
            ("One, two, three.", "1, 2, 3.")
        ] {
            XCTAssertEqual(DictatedNumberFormatter.format(spoken), expected)
        }
    }

    func testPreservesWeightOrdinaryPhrasesIdentifiersAndBoundaries() {
        for (spoken, expected) in [
            ("The parcel weighs five pounds.", "The parcel weighs 5 pounds."),
            ("Buy five pounds of potatoes.", "Buy 5 pounds of potatoes."),
            ("A five-pound baby.", "A 5-pound baby."),
            ("A twenty-pound note.", "A £20 note."),
            ("No one knows. I'm the one who asked.", "No one knows. I'm the one who asked."),
            ("One Direction and OneDrive.", "One Direction and OneDrive."),
            ("A one-off payment.", "A one-off payment."),
            ("We will work through it one by one.", "We will work through it one by one."),
            ("Thanks a million.", "Thanks a million."),
            ("one\n hundred", "1\n hundred"),
            ("Invoice AB451 is due on 05/11/2026 at 10:30.", "Invoice AB451 is due on 05/11/2026 at 10:30."),
            ("Visit https://one.example.com/two or email one@example.com.", "Visit https://one.example.com/two or email one@example.com."),
            ("Open /Users/one/two.txt and one_two.json.", "Open /Users/one/two.txt and one_two.json."),
            ("The pressure is five pounds per square inch.", "The pressure is 5 pounds per square inch."),
            ("Don't send seventeen pounds fifty, not seventy-five pounds.", "Don't send £17.50, not £75.")
        ] {
            XCTAssertEqual(DictatedNumberFormatter.format(spoken), expected)
        }
    }

    func testSterlingValuesMatchIndependentBritishNumberAndCurrencyFormatters() {
        let spoken = NumberFormatter()
        spoken.locale = Locale(identifier: "en_GB")
        spoken.numberStyle = .spellOut
        let currency = NumberFormatter()
        currency.locale = Locale(identifier: "en_GB")
        currency.numberStyle = .currency
        currency.currencyCode = "GBP"
        for pounds in [0, 1, 9, 20, 21, 99, 100, 451, 999, 1000, 2304, 999_999, 1_000_001] {
            for pence in [0, 1, 5, 10, 51, 99] {
                let input = "Pay \(spoken.string(from: NSNumber(value: pounds))!) pounds and \(spoken.string(from: NSNumber(value: pence))!) pence."
                let value = NSDecimalNumber(mantissa: UInt64(pounds * 100 + pence), exponent: -2, isNegative: false)
                let expected = "Pay \(currency.string(from: value)!)."
                XCTAssertEqual(DictatedNumberFormatter.format(input), expected, input)
                XCTAssertEqual(TranscriptCleanup.accepted(expected, original: input), expected, input)
            }
        }
    }
}
