import Foundation
import XCTest
import WhiskerFlowObjCSupport

final class ObjCExceptionShimTests: XCTestCase {
    func testObjectiveCExceptionBecomesAnErrorInsteadOfAborting() {
        var error: NSError?
        let succeeded = WFPerformCatchingObjCException({
            NSException(name: .invalidArgumentException, reason: "hardware format changed", userInfo: nil).raise()
        }, &error)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(error?.userInfo["exceptionName"] as? String, NSExceptionName.invalidArgumentException.rawValue)
        XCTAssertNil(error?.userInfo[NSLocalizedFailureReasonErrorKey], "The exception reason is not kept")
    }

    func testBlockRunsNormallyWithoutAnException() {
        var ran = false
        var error: NSError?
        XCTAssertTrue(WFPerformCatchingObjCException({ ran = true }, &error))
        XCTAssertTrue(ran)
        XCTAssertNil(error)
    }
}
