@testable import HarnessApp
import Foundation
import Sparkle
import Testing

@MainActor
@Suite("Sparkle notice callbacks")
struct UpdateDriverTests {
    @Test func cancelRepliesOnlyOnce() {
        let center = UpdateCardCenter()
        let driver = UpdateNoticeDriver(center: center, currentVersion: "0.1.0")
        var replies = 0
        driver.showUserInitiatedUpdateCheck { replies += 1 }
        let cancel = center.notices[0].actions[0]
        cancel.perform()
        cancel.perform()
        #expect(replies == 1)
        #expect(center.notices.isEmpty)
    }

    @Test func readyLaterAndInstallReplyOnlyOnce() {
        for install in [false, true] {
            let center = UpdateCardCenter()
            let driver = UpdateNoticeDriver(center: center, currentVersion: "0.1.0")
            var choices: [SPUUserUpdateChoice] = []
            driver.showReady { choices.append($0) }
            let action = center.notices[0].actions[install ? 1 : 0]
            action.perform()
            action.perform()
            #expect(choices == [install ? .install : .dismiss])
            #expect(center.notices.isEmpty == !install)
        }
    }

    @Test func downloadAndExtractionProgressReplaceTheNotice() {
        let center = UpdateCardCenter()
        let driver = UpdateNoticeDriver(center: center, currentVersion: "0.1.0")
        var presentations = 0
        center.onPresent = { presentations += 1 }
        driver.showDownloadInitiated(cancellation: {})
        #expect(center.notices[0].progress == .indeterminate)
        driver.showDownloadDidReceiveExpectedContentLength(200)
        driver.showDownloadDidReceiveData(ofLength: 100)
        #expect(center.notices[0].progress == .fraction(0.5))
        driver.showDownloadDidStartExtractingUpdate()
        #expect(center.notices[0].actions.isEmpty)
        driver.showExtractionReceivedProgress(0.75)
        #expect(center.notices[0].progress == .fraction(0.75))
        #expect(center.notices.count == 1)
        #expect(presentations == 1)
        driver.dismissUpdateInstallation()
        #expect(center.notices.isEmpty)
    }

    @Test func errorSurvivesSessionDismissalUntilAcknowledged() {
        let center = UpdateCardCenter()
        let driver = UpdateNoticeDriver(center: center, currentVersion: "0.1.0")
        var replies = 0
        driver.showUpdaterError(NSError(domain: "test", code: 1), acknowledgement: { replies += 1 })
        driver.dismissUpdateInstallation()
        #expect(center.notices[0].tone == .error)
        let dismiss = center.notices[0].onDismiss
        dismiss?()
        dismiss?()
        #expect(replies == 1)
        #expect(center.notices.isEmpty)
    }
}
