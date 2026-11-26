import XCTest

final class RecocoUITests: XCTestCase {
    #if targetEnvironment(simulator)
    // Launch argument overrides apply only to this test app, not the simulator or Photos.
    func testLocalizedOnboardingAndCleanupRoutes() {
        let cases = [
            ("en", "en_US", "How do you choose?", "Report tab", "Delete selected (1)"),
            ("ja", "ja_JP", "どうやって選ぶの？", "レポートタブ", "選んだ1枚を削除"),
            ("zh-Hant", "zh_TW", "怎麼挑照片？", "報告標籤頁", "刪除所選的 1 張"),
            ("vi", "vi_VN", "Recoco chọn như thế nào?", "Thẻ Báo cáo", "Xóa 1 ảnh đã chọn"),
            ("th", "th_TH", "เลือกให้อย่างไร", "แท็บรายงาน", "ลบ 1 รูปที่เลือก")
        ]
        for (language, region, next, report, selected) in cases {
            let arguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", region]
            let app = launch(route: "-ui-testing-route-onboarding", extraArguments: arguments)
            let button = app.buttons["onboarding.next"]
            XCTAssertTrue(button.waitForExistence(timeout: 8), language)
            XCTAssertEqual(button.label, next, language)
            XCTAssertTrue(button.isHittable, language)
            button.tap()
            XCTAssertTrue(button.isHittable, language)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Onboarding-\(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
            let home = launch(route: "-ui-testing-route-main", extraArguments: arguments + ["-ui-testing-home-batch"])
            let check = home.buttons["home.selectPhoto"]
            XCTAssertTrue(check.waitForExistence(timeout: 8), language)
            scrollToReveal(check, in: home)
            check.tap()
            XCTAssertEqual(home.buttons["home.deleteSelected"].label, selected, language)
            home.buttons[report].tap()
            XCTAssertTrue(home.staticTexts["report.totalDeletedCount"].waitForExistence(timeout: 8), language)
            let poll = home.buttons["report.cleanupPoll"]
            scrollToReveal(poll, in: home)
            poll.tap()
            XCTAssertTrue(home.buttons["poll.choice.video"].waitForExistence(timeout: 8), language)
            XCTAssertFalse(home.buttons["poll.submit"].isEnabled)
            home.terminate()
        }
    }

    func testEuropeanAndKoreanOnboardingActionsRemainVisible() {
        let cases = [("ko", "ko_KR", "어떻게 골라주나요?"), ("de", "de_DE", "Wie wählst du sie aus?"),
                     ("fr", "fr_FR", "Comment les choisis-tu ?"), ("pl", "pl_PL", "Jak je wybierasz?"),
                     ("ga", "ga_IE", "Conas a roghnaítear iad?"), ("el", "el_GR", "Πώς τις διαλέγεις;")]
        for (language, region, title) in cases {
            let app = launch(route: "-ui-testing-route-onboarding", extraArguments: [
                "-AppleLanguages", "(\(language))", "-AppleLocale", region
            ])
            let next = app.buttons["onboarding.next"]
            XCTAssertTrue(next.waitForExistence(timeout: 8), language)
            XCTAssertEqual(next.label, title, language)
            for page in 1...3 {
                XCTAssertTrue(next.isHittable, "\(language), page \(page)")
                XCTAssertTrue(app.frame.contains(next.frame), "\(language), page \(page): clipped CTA")
                if page == 2 {
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "Onboarding-\(language)"
                    shot.lifetime = .keepAlways
                    add(shot)
                }
                if page < 3 { next.tap() }
            }
            app.terminate()
        }
    }

    func testLanguageSwitchPreservesCleanupSelectionAndReport() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-batch", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ])
        let checkbox = app.buttons["home.selectPhoto"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 8))
        scrollToReveal(checkbox, in: app)
        checkbox.tap()
        XCTAssertEqual(app.buttons["home.deleteSelected"].label, "Delete selected (1)")
        app.terminate()

        // No reset: change only the language on the same installation and session.
        app.launchArguments = ["-ui-testing", "-ui-testing-route-main", "-ui-testing-home-batch",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let selected = app.buttons["home.deleteSelected"]
        XCTAssertTrue(selected.waitForExistence(timeout: 8))
        XCTAssertEqual(selected.label, "選んだ1枚を削除")
        let tab = app.buttons["tab.report"]
        XCTAssertEqual(tab.label, "レポートタブ")
        tab.tap()
        let total = app.staticTexts["report.totalDeletedCount"]
        XCTAssertTrue(total.waitForExistence(timeout: 8))
        XCTAssertTrue(total.label.contains("0"), "Changing language must not delete photos")
    }
    #endif

    func testGuestEntryKeepsLocalSessionAcrossNormalRelaunch() {
        // Exercise local-session routing with the simulator's current Photos
        // permission. First-use permission education is covered by its own test.
        // Seed only this isolated test app's local store. Complete onboarding
        // through its real controls so the second launch uses normal routing.
        let app = launch(route: "-ui-testing-route-onboarding", extraArguments: ["-ui-testing-with-record"])
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            scrollToReveal(next, in: app)
            next.tap()
        }
        let enter = app.buttons["auth.local"]
        continueWithoutAccount(in: app)
        declinePhotoPermissionIfPresented(in: app)
        XCTAssertTrue(app.buttons["홈 탭"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(next.exists)
        app.buttons["마이페이지 탭"].tap()
        let optionalAccount = app.buttons["profile.login"]
        XCTAssertTrue(optionalAccount.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["로그아웃"].exists)
        XCTAssertFalse(app.buttons["회원탈퇴"].exists)
        app.buttons["리포트 탭"].tap()
        let deletedCount = app.staticTexts["report.deletedCount"]
        XCTAssertTrue(deletedCount.waitForExistence(timeout: 5))
        let initialDeletedCount = deletedCount.label

        app.terminate()
        // No reset, route override, test seed, or development-session shortcut.
        app.launchArguments = []
        app.launch()
        // A declined system choice is respected on ordinary relaunch.
        XCTAssertFalse(app.buttons["photoPermission.request"].exists)
        XCTAssertTrue(app.buttons["홈 탭"].waitForExistence(timeout: 5))
        XCTAssertFalse(enter.exists)
        XCTAssertFalse(next.exists)
        app.buttons["마이페이지 탭"].tap()
        XCTAssertTrue(optionalAccount.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["로그아웃"].exists)
        XCTAssertFalse(app.buttons["회원탈퇴"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Local guest profile after ordinary relaunch"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["리포트 탭"].tap()
        XCTAssertTrue(app.staticTexts["report.monthlyTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(deletedCount.label, initialDeletedCount)
        // Historical records remain stored, but the cleanup release hides their UI.
        // Data retention is verified separately by the storage tests.
        XCTAssertFalse(app.buttons["report.openRecords"].exists)
    }

    func testCleanupReportShowsOnlyDeletionActivity() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-with-record"])
        app.buttons["리포트 탭"].tap()
        XCTAssertTrue(app.staticTexts["report.monthlyTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["이번 달 비운 사진"].exists)
        XCTAssertTrue(app.otherElements["report.calendar"].exists)
        XCTAssertFalse(app.staticTexts["이번 주 저장한 기록"].exists)
        XCTAssertFalse(app.staticTexts["보관 중인 전체 기록"].exists)
        XCTAssertFalse(app.buttons["report.openRecords"].exists)
        XCTAssertFalse(app.buttons["report.newRecord"].exists)
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "Cleanup report keeps historical records out of the decision surface"
        overview.lifetime = .keepAlways; add(overview)
        assertCleanupCalendarExploration(in: app, screenshotName: "Cleanup report past month and selected day")
    }

    func testReportOpensCleanupPollAndReturnsToTheSelectedDate() throws {
        let app = launch(route: "-ui-testing-route-main")
        app.buttons["리포트 탭"].tap()
        let count = app.staticTexts["report.totalDeletedCount"]
        let month = app.staticTexts["report.calendar.month"]
        let detail = app.descendants(matching: .any)["report.calendar.daySummary"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let originalCount = count.label
        app.buttons["report.calendar.previousMonth"].tap()
        let previousMonth = month.label
        let day = try XCTUnwrap(visibleCalendarDays(in: app).last)
        tapVisibleCalendarDay(day, in: app)
        assertCalendarResultVisible(detail, in: app)
        let selectedDate = detail.label

        let pollEntry = app.buttons["report.cleanupPoll"]
        scrollToReveal(pollEntry, in: app)
        pollEntry.tap()
        XCTAssertTrue(app.buttons["poll.choice.video"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["poll.showResults"].exists)
        XCTAssertFalse(app.buttons["poll.submit"].isEnabled)
        app.buttons["뒤로"].tap()

        XCTAssertTrue(pollEntry.waitForExistence(timeout: 5))
        XCTAssertEqual(month.label, previousMonth)
        XCTAssertEqual(detail.label, selectedDate)
        XCTAssertEqual(count.label, originalCount)
        XCTAssertTrue(app.buttons["홈 탭"].isHittable)
    }

    func testOptionalAccountSheetCanCloseWithoutChangingCleanupProgress() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-with-record", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        XCTAssertTrue(app.buttons["리포트 탭"].waitForExistence(timeout: 5))
        app.buttons["리포트 탭"].tap()
        let count = app.staticTexts["report.deletedCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let before = count.label
        app.buttons["마이페이지 탭"].tap()
        let login = app.buttons["profile.login"]
        XCTAssertTrue(login.waitForExistence(timeout: 5))
        scrollToReveal(login, in: app)
        login.tap()
        let guest = app.buttons["auth.local"]
        XCTAssertTrue(guest.waitForExistence(timeout: 5))
        XCTAssertEqual(guest.label, "로그인 없이 계속하기")
        let close = app.buttons["auth.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        XCTAssertTrue(login.waitForExistence(timeout: 3))
        XCTAssertFalse(guest.exists, "Dismissing optional login returns to the existing screen")
        XCTAssertFalse(app.buttons["로그아웃"].exists)
        app.buttons["리포트 탭"].tap()
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        XCTAssertEqual(count.label, before, "Cancelling account entry must not alter the cleanup report")
    }

    func testCleanupReportCalendarIsReachableAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-with-record", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        app.buttons["리포트 탭"].tap()
        XCTAssertTrue(app.otherElements["report.calendar"].waitForExistence(timeout: 5))
        assertCleanupCalendarExploration(in: app, screenshotName: "Cleanup calendar and day card at accessibility text size")
        XCTAssertFalse(app.buttons["report.newRecord"].exists)
    }

    func testCleanupCalendarCurrentDayResultRevealsAgainAfterManualScroll() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-with-record"])
        app.buttons["리포트 탭"].tap()
        let scroll = app.scrollViews["report.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let result = app.descendants(matching: .any)["report.calendar.daySummary"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        // A four-week month may already fit. Keep current-month coverage when
        // possible, otherwise use an earlier longer month to exercise hiding.
        let previous = app.buttons["report.calendar.previousMonth"]
        for _ in 0..<12 {
            if !calendarResultIsFullyVisible(result, in: app) { break }
            previous.tap()
        }
        XCTAssertGreaterThan(result.frame.height, 0)
        XCTAssertGreaterThan(result.frame.maxY, calendarVisibleBounds(in: app).maxY,
                             "The scenario must start with a real result card below the viewport")
        XCTAssertFalse(calendarResultIsFullyVisible(result, in: app),
                       "Start with the result below the visible report, without a helper scrolling it into view")
        guard let day = visibleCalendarDays(in: app).last else {
            XCTFail("No date can be tapped without scrolling\n\(app.debugDescription)")
            return
        }
        let dateParts = (day.label.components(separatedBy: ",").first ?? "").split(separator: " ")
        XCTAssertEqual(dateParts.count, 3)
        guard dateParts.count == 3 else { return }
        let expectedDate = "\(dateParts[1]) \(dateParts[2])"
        tapVisibleCalendarDay(day, in: app)
        assertCalendarResultVisible(result, in: app)
        XCTAssertTrue(result.label.contains(expectedDate))

        // A second tap must not reposition an already visible result. Use the
        // screen coordinate, not XCUIElement.tap(), which may assist scrolling.
        let visibleResultFrame = result.frame
        let visibleDayFrame = day.frame
        let anotherVisibleDay = visibleCalendarDays(in: app).last { $0.identifier != day.identifier } ?? day
        tapVisibleCalendarDay(anotherVisibleDay, in: app)
        assertCalendarResultVisible(result, in: app)
        let unexpectedlyMoved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(result.frame.minY - visibleResultFrame.minY) > 1
                || abs(day.frame.minY - visibleDayFrame.minY) > 1
        }, object: nil)
        unexpectedlyMoved.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedlyMoved], timeout: 0.7), .completed,
                       "A fully visible result must stay in place after the selection settles")
        XCTAssertEqual(result.frame.minY, visibleResultFrame.minY, accuracy: 1)
        XCTAssertEqual(day.frame.minY, visibleDayFrame.minY, accuracy: 1)

        // Mimic the user moving back up, then selecting the exact same date.
        // No selected-state query or scrollToReveal runs after the tap.
        let repeatedDay = anotherVisibleDay
        let repeatedDateParts = (repeatedDay.label.components(separatedBy: ",").first ?? "").split(separator: " ")
        XCTAssertEqual(repeatedDateParts.count, 3)
        guard repeatedDateParts.count == 3 else { return }
        let repeatedDate = "\(repeatedDateParts[1]) \(repeatedDateParts[2])"
        for _ in 0..<5 {
            if !calendarResultIsFullyVisible(result, in: app),
               calendarFrameIsFullyVisible(repeatedDay.frame, in: app) { break }
            app.swipeDown()
        }
        XCTAssertFalse(calendarResultIsFullyVisible(result, in: app), "Manual scrolling must hide the result first")
        tapVisibleCalendarDay(repeatedDay, in: app)
        assertCalendarResultVisible(result, in: app)
        XCTAssertTrue(result.label.contains(repeatedDate))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Current month same-day result after manual scroll and coordinate tap"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testCompletionRecognizesKeptPhotosAndOffersFinishing() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-completion"])
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.completionTitle"].label, "모두 살펴봤어요.")
        XCTAssertFalse(app.staticTexts["home.clearedCount"].exists)
        let finish = app.buttons["home.finishSession"]
        let more = app.buttons["home.morePhotos"]
        XCTAssertEqual(finish.label, "리포트 보기")
        XCTAssertEqual(more.label, "조금 더 살펴보기")
        XCTAssertLessThanOrEqual(finish.frame.maxY, more.frame.minY,
                                 "Finishing this batch takes priority over starting another")
        XCTAssertFalse(app.buttons["home.selectMorePhotos"].exists)
        XCTAssertFalse(app.staticTexts["home.scanProgress"].exists,
                       "Completion does not start another scan automatically")
        scrollToReveal(finish, in: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Completed without deleting photos"; screenshot.lifetime = .keepAlways; add(screenshot)
        finish.tap()
        XCTAssertTrue(app.staticTexts["report.monthlyTitle"].waitForExistence(timeout: 4))
        app.buttons["홈 탭"].tap()
        XCTAssertEqual(app.staticTexts["home.completionTitle"].label, "모두 살펴봤어요.")
    }

    func testExhaustedCompletionDoesNotOfferEmptyNextBatch() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-completion", "-ui-testing-completion-exhausted"])
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.completionTitle"].label, "모두 살펴봤어요.")
        XCTAssertEqual(app.staticTexts["home.nextStepMessage"].label, "내일 앱을 열면 새 정리 후보를 찾아볼게요.")
        XCTAssertFalse(app.buttons["home.morePhotos"].exists)
        XCTAssertFalse(app.buttons["home.retryScan"].exists)
        XCTAssertFalse(app.buttons["home.selectMorePhotos"].exists)
        XCTAssertFalse(app.buttons["home.refreshPhotos"].exists)
        let finish = app.buttons["home.finishSession"]
        XCTAssertEqual(finish.label, "리포트 보기")
        scrollToReveal(finish, in: app)
        finish.tap()
        XCTAssertTrue(app.staticTexts["report.monthlyTitle"].waitForExistence(timeout: 4))
    }

    func testLimitedCompletionOffersPhotoSelectionAsTheNextStep() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-completion", "-ui-testing-completion-exhausted", "-ui-testing-completion-limited"])
        let select = app.buttons["home.selectMorePhotos"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        let finish = app.buttons["home.finishSession"]
        XCTAssertEqual(finish.label, "리포트 보기")
        XCTAssertEqual(select.label, "사진 더 선택하기")
        XCTAssertLessThanOrEqual(finish.frame.maxY, select.frame.minY,
                                 "Granting more access is optional after completing the batch")
        scrollToReveal(select, in: app)
        XCTAssertTrue(select.isHittable)
        XCTAssertFalse(app.buttons["home.morePhotos"].exists)
        XCTAssertTrue(app.staticTexts["home.nextStepMessage"].label.contains("사진을 더 선택"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Limited completion next photo selection"; shot.lifetime = .keepAlways; add(shot)
    }

    func testAdditionalSearchWithoutCandidatesClearlyReportsResultAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-completion", "-ui-testing-completion-exhausted", "-ui-testing-completion-limited", "-ui-testing-completion-empty-search", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let title = app.staticTexts["home.completionTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "모두 살펴봤어요.", "An unsuccessful extra search must not erase the completed batch")
        XCTAssertTrue(app.staticTexts["home.nextStepMessage"].label.contains("추가로 추천할 사진을 찾지 못했어요."))
        let finish = app.buttons["home.finishSession"]
        XCTAssertEqual(finish.label, "리포트 보기")
        scrollToReveal(finish, in: app)
        XCTAssertTrue(finish.isHittable)
        XCTAssertLessThanOrEqual(finish.frame.maxY, app.buttons["홈 탭"].frame.minY)
        let select = app.buttons["home.selectMorePhotos"]
        scrollToReveal(select, in: app)
        XCTAssertTrue(select.isHittable)
        XCTAssertLessThanOrEqual(select.frame.maxY, app.buttons["홈 탭"].frame.minY)
        XCTAssertFalse(app.buttons["home.morePhotos"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Empty additional search at large text"; shot.lifetime = .keepAlways; add(shot)
    }

    func testPartialFailureCompletionKeepsResultAndAllowsFinishingAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-completion", "-ui-testing-completion-unavailable", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.completionTitle"].label, "사진 3장을 살펴봤어요.")
        let finish = app.buttons["home.finishSession"]
        XCTAssertEqual(finish.label, "리포트 보기")
        scrollToReveal(finish, in: app)
        XCTAssertTrue(finish.isHittable)
        XCTAssertLessThanOrEqual(finish.frame.maxY, app.buttons["홈 탭"].frame.minY)
        let retry = app.buttons["home.retryScan"]
        scrollToReveal(retry, in: app)
        XCTAssertTrue(retry.isHittable)
        XCTAssertEqual(retry.label, "다시 시도하기")
        XCTAssertLessThanOrEqual(retry.frame.maxY, app.buttons["홈 탭"].frame.minY)
        XCTAssertEqual(app.staticTexts["home.nextSessionStatus"].label, "사진을 확인하지 못했어요.")
        XCTAssertFalse(app.buttons["home.morePhotos"].exists)
        XCTAssertTrue(app.buttons["home.finishSession"].exists)
    }

    func testLimitedCompletionDoesNotRequestMorePermissionWhilePhotosRemain() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-completion", "-ui-testing-completion-limited"
        ])
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["home.finishSession"].label, "오늘은 여기까지")
        XCTAssertEqual(app.buttons["home.morePhotos"].label, "조금 더 살펴보기")
        XCTAssertFalse(app.buttons["home.selectMorePhotos"].exists,
                       "Do not ask for another photo-selection step when accessible photos can be checked")
        XCTAssertFalse(app.buttons["home.retryScan"].exists)
    }

    func testCompletionContinueIsOptionalAndReachableAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-completion", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        let finish = app.buttons["home.finishSession"]
        XCTAssertEqual(finish.label, "리포트 보기")
        scrollToReveal(finish, in: app)
        XCTAssertTrue(finish.isHittable)
        XCTAssertLessThanOrEqual(finish.frame.maxY, app.buttons["홈 탭"].frame.minY)
        let more = app.buttons["home.morePhotos"]
        XCTAssertEqual(more.label, "조금 더 살펴보기")
        scrollToReveal(more, in: app)
        XCTAssertTrue(more.isHittable)
        XCTAssertLessThanOrEqual(more.frame.maxY, app.buttons["홈 탭"].frame.minY)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Optional continuation after completion at accessibility text size"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCompletionExplainsSubscriptionBeforeOptionalContinuation() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-completion", "-ui-testing-completion-subscription", "-subscription-testing"
        ])
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.completionTitle"].label, "모두 살펴봤어요.")
        XCTAssertTrue(app.staticTexts["home.nextStepMessage"].label.contains("구독"),
                      "The optional continuation must explain that a subscription is required")
        let finish = app.buttons["home.finishSession"]
        let more = app.buttons["home.morePhotos"]
        XCTAssertEqual(finish.label, "리포트 보기")
        XCTAssertEqual(more.label, "조금 더 살펴보기")
        XCTAssertLessThanOrEqual(finish.frame.maxY, more.frame.minY)
        XCTAssertFalse(app.staticTexts["subscription.terms"].exists,
                       "Finishing three photos must not open a subscription sheet automatically")
        scrollToReveal(more, in: app)
        more.tap()
        let terms = app.staticTexts["subscription.terms"]
        XCTAssertTrue(terms.waitForExistence(timeout: 5))
        XCTAssertTrue(terms.label.contains("7일"))
        XCTAssertFalse(app.staticTexts["home.scanProgress"].exists)
    }

    func testLimitedExhaustedCompletionExplainsSubscriptionBeforeRequestingPhotos() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-completion", "-ui-testing-completion-subscription", "-subscription-testing",
            "-ui-testing-completion-exhausted", "-ui-testing-completion-limited"
        ])
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["home.finishSession"].label, "오늘은 여기까지")
        XCTAssertTrue(app.staticTexts["home.nextStepMessage"].label.contains("구독"))
        XCTAssertFalse(app.buttons["home.selectMorePhotos"].exists)
        let more = app.buttons["home.morePhotos"]
        XCTAssertEqual(more.label, "조금 더 살펴보기")
        scrollToReveal(more, in: app)
        more.tap()
        XCTAssertTrue(app.staticTexts["subscription.terms"].waitForExistence(timeout: 5))
    }

    func testFirstRecommendationCanPauseAndResumeAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-first-scan", "-ui-testing-first-scan-slow",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        XCTAssertTrue(app.staticTexts["home.slowScan"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["home.scanProgress"].exists,
                       "Internal analysis windows are not the user's recommendation progress")
        let waiting = XCTAttachment(screenshot: app.screenshot())
        waiting.name = "Slow photo check at large text"; waiting.lifetime = .keepAlways; add(waiting)
        let pause = app.buttons["home.pauseScan"]
        // Home actions follow the content, including at accessibility text sizes.
        scrollToReveal(pause, in: app)
        XCTAssertTrue(pause.isHittable, "Pause remains reachable in the shared reading flow")
        XCTAssertLessThanOrEqual(pause.frame.maxY, app.buttons["홈 탭"].frame.minY)
        pause.tap()
        XCTAssertTrue(app.staticTexts["home.scanPaused"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["home.scanProgress"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Paused first recommendation at large text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let resume = app.buttons["home.resumeScan"]
        scrollToReveal(resume, in: app)
        resume.tap()
        XCTAssertTrue(app.staticTexts["home.slowScan"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["home.scanProgress"].exists)
        app.buttons["리포트 탭"].tap()
        XCTAssertTrue(app.staticTexts["report.monthlyTitle"].waitForExistence(timeout: 4))
        app.buttons["홈 탭"].tap()
        XCTAssertTrue(app.staticTexts["home.slowScan"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["home.scanPaused"].exists,
                       "Changing tabs is an interruption, not an explicit request to pause")
        XCTAssertFalse(app.staticTexts["home.scanProgress"].exists)
        // Rapid tab changes cancel the outgoing work and resume on return.
        app.buttons["리포트 탭"].tap()
        app.buttons["홈 탭"].tap()
        XCTAssertTrue(app.staticTexts["home.slowScan"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["home.scanPaused"].exists)
    }

    func testFirstVerifiedPhotoArrivesWithoutCountingItAsDeleted() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-first-scan"])
        XCTAssertTrue(app.staticTexts["home.photoCounter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/1")
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
        XCTAssertFalse(app.staticTexts["home.scanProgress"].exists)
        XCTAssertTrue(app.buttons["사진 비우기"].exists)
    }

    func testPreparingPhotoKeepsHomeLayoutAndDisablesDecisions() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-first-scan", "-ui-testing-first-scan-slow"
        ])
        XCTAssertTrue(app.staticTexts["home.loadingTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.weeklySummary"].exists)
        let photo = app.descendants(matching: .any)["home.preparingPhoto"].firstMatch
        XCTAssertTrue(photo.exists)
        XCTAssertGreaterThan(photo.frame.width, 0)
        XCTAssertEqual(photo.frame.width, photo.frame.height, accuracy: 1)
        let remove = app.buttons["home.deleteSelected"]
        let pause = app.buttons["home.pauseScan"]
        XCTAssertTrue(remove.exists)
        XCTAssertFalse(remove.isEnabled)
        XCTAssertTrue(pause.exists)
        XCTAssertLessThanOrEqual(photo.frame.maxY, remove.frame.minY)
        XCTAssertLessThanOrEqual(remove.frame.maxY, pause.frame.minY)
        XCTAssertLessThanOrEqual(pause.frame.maxY, app.buttons["홈 탭"].frame.minY)
        XCTAssertFalse(app.staticTexts["사진은 자동으로 지우지 않아요."].exists)
        let waiting = XCTAttachment(screenshot: app.screenshot())
        waiting.name = "Home keeps photo and action positions while preparing"
        waiting.lifetime = .keepAlways; add(waiting)
    }

    func testLimitedAccessWithoutPhotosOffersSelectionInsteadOfCompletion() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-first-scan", "-ui-testing-first-scan-limited"])
        let title = app.staticTexts["home.scanStatusTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "선택한 사진이 없어요.")
        XCTAssertTrue(app.buttons["home.selectMorePhotos"].isHittable)
        XCTAssertFalse(app.buttons["home.retryScan"].exists)
        XCTAssertTrue(app.staticTexts["home.clearedCount"].exists)
        XCTAssertFalse(app.staticTexts["home.completionTitle"].exists)
        XCTAssertLessThanOrEqual(app.buttons["home.selectMorePhotos"].frame.maxY + 8, app.buttons["홈 탭"].frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Limited library with no selected photos"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testEmptyHomeOpensSavedRecordsDirectlyAndCanReopen() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-first-scan", "-ui-testing-first-scan-limited", "-ui-testing-with-record"
        ])
        let records = app.buttons["home.openRecords"]
        XCTAssertTrue(records.waitForExistence(timeout: 5))
        scrollToReveal(records, in: app); records.tap()
        XCTAssertTrue(app.textFields["records.search"].waitForExistence(timeout: 5))
        app.buttons["뒤로"].tap()
        XCTAssertTrue(app.staticTexts["report.monthlyTitle"].waitForExistence(timeout: 4))
        app.buttons["홈 탭"].tap()
        scrollToReveal(records, in: app); records.tap()
        XCTAssertTrue(app.textFields["records.search"].waitForExistence(timeout: 4))
    }

    func testConfirmedDeletionReturnsToNextPhotoAndRecoveryAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-delete-success",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let entry = app.buttons["사진 비우기"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        scrollToReveal(entry, in: app)
        entry.tap()
        let confirm = app.buttons["비우기"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["home.photoCounter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/2")
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 1장 비웠어요")
        XCTAssertFalse(app.buttons["deletion.continue"].exists)
        XCTAssertFalse(app.staticTexts["deletion.success"].exists)
        let recovery = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "마음이 바뀌었다면")).firstMatch
        scrollToReveal(recovery, in: app)
        recovery.tap()
        let steps = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "사진 앱에서 ‘최근 삭제된 항목’")).firstMatch
        scrollToReveal(steps, in: app)
        XCTAssertTrue(steps.isHittable)
        XCTAssertLessThanOrEqual(steps.frame.maxY, app.buttons["홈 탭"].frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Next photo retains optional recovery at large text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testThreeDeletionsContinueAutomaticallyAndFinishOnlyAfterLastPhoto() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-delete-success", "-ui-testing-with-record"
        ])
        for deleted in 1...3 {
            let clear = app.buttons["사진 비우기"]
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
            scrollToReveal(clear, in: app)
            clear.tap()
            let confirm = app.buttons["비우기"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 3))
            confirm.tap()
            XCTAssertFalse(app.buttons["deletion.continue"].exists)
            if deleted < 3 {
                let counter = app.staticTexts["home.photoCounter"]
                XCTAssertTrue(counter.waitForExistence(timeout: 5))
                XCTAssertEqual(counter.label, "1/\(3 - deleted)")
                XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 \(deleted)장 비웠어요")
                XCTAssertTrue(app.buttons["home.photoExplanation"].firstMatch.label.contains("테스트 사진 \(deleted + 1)"))
                XCTAssertFalse(app.staticTexts["home.completionTitle"].exists)
            }
        }
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["home.photoCounter"].exists)
        XCTAssertFalse(app.buttons["deletion.continue"].exists)
        app.buttons["리포트 탭"].tap()
        XCTAssertTrue(app.staticTexts["report.deletedCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["report.deletedCount"].label, "3장")
        XCTAssertEqual(app.staticTexts["report.savedCount"].label, "0개")
        openSavedRecords(app)
        XCTAssertTrue(app.staticTexts["남긴 기록 1개"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["테스트로 남긴 기억, 기록 자세히 보기"].exists)
    }

    func testSystemDeletionCancellationKeepsPhotoAndCount() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-delete-cancel"])
        XCTAssertTrue(app.buttons["사진 비우기"].waitForExistence(timeout: 5))
        app.buttons["사진 비우기"].tap()
        app.buttons["비우기"].tap()
        XCTAssertTrue(app.staticTexts["deletion.cancelled"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["deletion.success"].exists)
        app.buttons["취소"].tap()
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/3")
    }

    func testDeletionFailureDoesNotAdvanceAndCanBeRetried() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-delete-failure"])
        XCTAssertTrue(app.buttons["사진 비우기"].waitForExistence(timeout: 5))
        app.buttons["사진 비우기"].tap()
        app.buttons["비우기"].tap()
        XCTAssertTrue(app.alerts["사진을 비우지 못했어요."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["deletion.success"].exists)
        app.alerts.buttons["확인"].tap()
        XCTAssertTrue(app.buttons["비우기"].isEnabled)
        app.buttons["취소"].tap()
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/3")
    }

    func testReflectionChosenDeletionCancellationKeepsPhotoAndCount() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-mixed-reflection", "-ui-testing-delete-cancel"])
        XCTAssertTrue(app.buttons["home.nextPhoto"].waitForExistence(timeout: 5))
        app.buttons["home.nextPhoto"].tap()
        XCTAssertEqual(app.staticTexts["home.curationReason"].label, "다시 살펴볼 사진을 골랐어요.")
        assertNoPhotoCategoryText(app)
        let clear = app.buttons["사진 비우기"]
        scrollToReveal(clear, in: app); clear.tap()
        XCTAssertTrue(app.staticTexts["이 사진을 비울까요?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["사진 앱의 최근 삭제된 항목으로 이동해요."].exists)
        assertNoPhotoCategoryText(app)
        app.buttons["비우기"].tap()
        XCTAssertTrue(app.staticTexts["deletion.cancelled"].waitForExistence(timeout: 3))
        app.buttons["취소"].tap()
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "2/3")
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
        XCTAssertEqual(app.staticTexts["home.curationReason"].label, "다시 살펴볼 사진을 골랐어요.")
        assertNoPhotoCategoryText(app)
    }

    func testReflectionChosenDeletionSuccessCountsOnlySelectedPhoto() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-mixed-reflection", "-ui-testing-delete-success"])
        XCTAssertTrue(app.buttons["home.nextPhoto"].waitForExistence(timeout: 5))
        app.buttons["home.nextPhoto"].tap()
        let clear = app.buttons["사진 비우기"]
        scrollToReveal(clear, in: app); clear.tap()
        XCTAssertTrue(app.staticTexts["이 사진을 비울까요?"].waitForExistence(timeout: 3))
        assertNoPhotoCategoryText(app)
        app.buttons["비우기"].tap()
        XCTAssertTrue(app.staticTexts["사진 1장 비웠어요. 최근 삭제된 항목에서 복구할 수 있어요."].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["home.photoCounter"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["deletion.continue"].exists)
        XCTAssertFalse(app.staticTexts["deletion.success"].exists)
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 1장 비웠어요")
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "2/2")
        XCTAssertTrue(app.buttons["home.photoExplanation"].firstMatch.label.contains("테스트 사진 3"))
    }

    func testReflectionChosenDeletionFailureDoesNotAdvance() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-mixed-reflection", "-ui-testing-delete-failure"])
        XCTAssertTrue(app.buttons["home.nextPhoto"].waitForExistence(timeout: 5))
        app.buttons["home.nextPhoto"].tap()
        let clear = app.buttons["사진 비우기"]
        scrollToReveal(clear, in: app); clear.tap()
        XCTAssertTrue(app.staticTexts["이 사진을 비울까요?"].waitForExistence(timeout: 3))
        assertNoPhotoCategoryText(app)
        app.buttons["비우기"].tap()
        XCTAssertTrue(app.alerts["사진을 비우지 못했어요."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["deletion.success"].exists)
        app.alerts.buttons["확인"].tap()
        app.buttons["취소"].tap()
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "2/3")
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
    }

    func testUnavailablePhotosOfferRetryWithoutClaimingNoCandidates() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-scan-unavailable"])
        let title = app.staticTexts["home.scanStatusTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "사진을 확인하지 못했어요.")
        XCTAssertFalse(app.staticTexts["지금은 추천할 사진이 없어요."].exists)
        let retry = app.buttons["home.retryScan"]
        scrollToReveal(retry, in: app)
        XCTAssertEqual(retry.label, "다시 시도하기")
        XCTAssertTrue(retry.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Unavailable photos and retry"
        attachment.lifetime = .keepAlways
        add(attachment)
        retry.tap()
        XCTAssertEqual(title.label, "지금은 추천할 사진이 없어요.")
        XCTAssertFalse(retry.exists)
        // An empty result keeps the Home shell and must not count a retry as a deletion.
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
    }

    func testInaccessiblePhotosExplainRecoveryWithoutLosingProgress() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-scan-unavailable", "-ui-testing-scan-inaccessible"
        ])
        let title = app.staticTexts["home.scanStatusTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "이전에 보던 사진에 접근할 수 없어요.")
        let help = app.buttons["home.scanHelp"]
        scrollToReveal(help, in: app); help.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "비교 사진을 함께 선택")).firstMatch.exists)
        let other = app.buttons["home.findOtherPhotos"]
        scrollToReveal(other, in: app)
        XCTAssertTrue(other.isHittable)
        XCTAssertTrue(app.buttons["home.selectMorePhotos"].exists)
        XCTAssertFalse(app.buttons["home.retryScan"].exists, "An access change needs a selection action, not repeated reads")
        XCTAssertFalse(app.staticTexts["home.completionTitle"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Inaccessible photo recovery actions"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testPartialReadFailureOffersContinueAtLargeTextSize() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-scan-unavailable", "-ui-testing-scan-has-fresh",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let retry = app.buttons["home.retryScan"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        scrollToReveal(retry, in: app)
        XCTAssertEqual(retry.label, "이어서 살펴보기")
        XCTAssertTrue(retry.isHittable)
        XCTAssertLessThanOrEqual(retry.frame.maxY, app.buttons["홈 탭"].frame.minY)
    }

    func testCleanupReleaseProfileHasNoSubscriptionEntry() {
        let app = launch(route: "-ui-testing-route-main")
        app.buttons["마이페이지 탭"].tap()
        XCTAssertTrue(app.buttons["profile.photoAccess"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profile.notifications"].exists)
        XCTAssertFalse(app.buttons["profile.subscription"].exists)
        XCTAssertFalse(app.buttons["구독 안내 및 관리"].exists)
        XCTAssertFalse(app.buttons["report.newRecord"].exists)
        let version = app.staticTexts["profile.appVersion"]
        scrollToReveal(version, in: app)
        XCTAssertTrue(version.label.contains("("), "Installed build is visible without opening a diagnostic screen")
    }

    func testNewUserCompletesAllOnboardingPages() {
        // UserDefaults reset does not reset Photos permission. Make this
        // first-use path deterministic without changing the real app routing.
        XCUIApplication().resetAuthorizationStatus(for: .photos)
        let app = launch(route: "-ui-testing-route-onboarding")
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "어떻게 골라주나요?")
        XCTAssertTrue(app.staticTexts["쌓인 사진,\n정리할 것부터 골라드려요."].exists)
        next.tap()
        XCTAssertTrue(app.staticTexts["오늘은 제가\n최대 세 장 골라볼게요."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["onboarding.sampleComparison"].exists)
        next.tap()
        XCTAssertTrue(app.staticTexts["남기고 싶은 사진은\n그대로 두세요."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["무료 이용과 구독 안내"].exists)
        XCTAssertEqual(next.label, "사진 정리 시작하기")
        let introduction = XCTAttachment(screenshot: app.screenshot())
        introduction.name = "Cleanup onboarding respects keeping photos"
        introduction.lifetime = .keepAlways; add(introduction)
        next.tap()
        continueWithoutAccount(in: app)
        XCTAssertTrue(app.buttons["photoPermission.request"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["auth.local"].exists)
    }

    func testRecordDraftSurvivesDismissAndReopen() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel"])
        let record = app.buttons["기록하기"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 3), app.debugDescription)
        input.tap()
        input.typeText("A quiet afternoon")
        app.swipeUp()
        app.buttons["뒤로"].tap()
        XCTAssertTrue(record.waitForExistence(timeout: 3))
        record.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "A quiet afternoon")
        app.swipeUp()
        app.buttons["기록 미리보기"].tap()
        let save = app.buttons["record.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let narrative = app.textViews["남길 기록"]
        narrative.tap()
        narrative.typeText(" — edited")
        app.buttons["완료"].tap()
        let visibleBack = app.buttons.matching(NSPredicate(format: "label == %@", "뒤로"))
            .allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(visibleBack.count, 1, "Only the active preview's Back control should be hittable.")
        guard let previewBack = visibleBack.first else { return }
        previewBack.tap()
        let previewAgain = app.buttons["기록 미리보기"]
        scrollToReveal(previewAgain, in: app)
        previewAgain.tap()
        XCTAssertTrue(narrative.waitForExistence(timeout: 5))
        XCTAssertTrue((narrative.value as? String)?.contains("edited") == true,
                      "Reopening a preview must retain the user's manual edit.")
        XCTAssertFalse(app.buttons["공유하기"].exists)
        scrollToReveal(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["기록을 저장했어요."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["home.photoCounter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/2")
        XCTAssertTrue(app.buttons["home.photoExplanation"].firstMatch.label.contains("테스트 사진 2"))
        XCTAssertFalse(app.staticTexts["record.saved"].exists)
        XCTAssertFalse(app.buttons["record.save"].exists)
        XCTAssertFalse(app.buttons["record.done"].exists)
        assertPhotoActionPair(app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home record save returns directly to next photo"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["리포트 탭"].tap()
        openSavedRecords(app)
        XCTAssertTrue(app.staticTexts["남긴 기록 1개"].waitForExistence(timeout: 5))
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A quiet afternoon")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
        saved.tap()
        XCTAssertTrue(app.staticTexts["records.detailText"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["records.detailText"].label.contains("edited"))
        app.buttons["뒤로"].tap()
        XCTAssertTrue(app.staticTexts["남긴 기록 1개"].waitForExistence(timeout: 3))
        app.buttons["뒤로"].tap()
        XCTAssertTrue(app.staticTexts["report.savedCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["report.savedCount"].label, "1개")
    }

    func testEditedRecordPreviewSurvivesSourceChangesAndRelaunch() {
        // Simulator fixtures only. Relaunch below keeps the same draft without
        // repeating the reset or seeding a replacement record.
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel"])
        let record = app.buttons["기록하기"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        scrollToReveal(record, in: app)
        record.tap()

        let input = app.textViews["나의 한 줄"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("An afternoon by the sea")
        app.buttons["완료"].tap()
        let preview = app.buttons["기록 미리보기"]
        scrollToReveal(preview, in: app)
        preview.tap()

        let narrative = app.textViews["남길 기록"]
        XCTAssertTrue(narrative.waitForExistence(timeout: 5))
        scrollToReveal(narrative, in: app)
        narrative.tap()
        narrative.typeText(" — my edited memory")
        app.buttons["완료"].tap()
        guard let edited = narrative.value as? String else {
            XCTFail("Edited preview must expose its text")
            return
        }
        XCTAssertTrue(edited.contains("my edited memory"))

        let visibleBack = app.buttons.matching(NSPredicate(format: "label == %@", "뒤로"))
            .allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(visibleBack.count, 1)
        guard let back = visibleBack.first else { return }
        back.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.swipeDown()
        input.tap()
        input.typeText(" with a changed original")
        app.buttons["완료"].tap()
        let changedOriginal = input.value as? String
        XCTAssertTrue(changedOriginal?.contains("changed original") == true)
        let preservedNotice = app.staticTexts["record.editedPreviewPreserved"]
        scrollToReveal(preview, in: app)
        XCTAssertTrue(preservedNotice.exists)
        preview.tap()
        XCTAssertTrue(narrative.waitForExistence(timeout: 5))
        XCTAssertEqual(narrative.value as? String, edited,
                       "Editing the original input must not replace the manually edited preview")

        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-route-main", "-ui-testing-home-carousel"]
        app.launch()
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        scrollToReveal(record, in: app)
        record.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, changedOriginal)
        scrollToReveal(preview, in: app)
        preview.tap()
        XCTAssertTrue(narrative.waitForExistence(timeout: 5))
        XCTAssertEqual(narrative.value as? String, edited,
                       "Relaunch must restore the edited draft, not regenerate it from the original")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Edited record survives original input changes and relaunch"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testRecordSaveAtLargeTextReturnsToReachableNextActions() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let record = app.buttons["기록하기"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        scrollToReveal(record, in: app); record.tap()
        let input = app.textViews["나의 한 줄"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap(); input.typeText("A lasting memory")
        let keyboardDone = app.buttons["완료"]
        XCTAssertTrue(keyboardDone.isHittable)
        keyboardDone.tap()
        let preview = app.buttons["기록 미리보기"]
        scrollToReveal(preview, in: app); preview.tap()
        let save = app.buttons["record.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        scrollToReveal(save, in: app); save.tap()
        XCTAssertTrue(app.staticTexts["home.photoCounter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/2")
        XCTAssertFalse(app.staticTexts["record.saved"].exists)
        XCTAssertFalse(app.buttons["record.save"].exists)
        XCTAssertFalse(app.buttons["record.done"].exists)
        // Accessibility text deliberately stacks the primary above secondary.
        let clear = app.buttons["사진 비우기"]
        for button in [clear, record] {
            scrollToReveal(button, in: app)
            XCTAssertTrue(button.isHittable && button.isEnabled)
        }
        XCTAssertLessThan(clear.frame.maxY, record.frame.minY)
        XCTAssertEqual(clear.frame.minX, record.frame.minX, accuracy: 1)
        XCTAssertLessThanOrEqual(record.frame.maxY, app.buttons["홈 탭"].frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home record continuation at large text"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["리포트 탭"].tap()
        openSavedRecords(app)
        XCTAssertTrue(app.staticTexts["남긴 기록 1개"].waitForExistence(timeout: 5))
    }

    func testOutOfOrderRecordSaveKeepsOtherPhotosAndLastSaveShowsCompletion() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-with-record"
        ])
        let next = app.buttons["home.nextPhoto"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        next.tap()
        saveCurrentHomeRecord("Third photo saved first", in: app)
        let counter = app.staticTexts["home.photoCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "2/2")
        XCTAssertTrue(app.buttons["home.photoExplanation"].firstMatch.label.contains("테스트 사진 2"))
        XCTAssertFalse(app.buttons["record.done"].exists)
        // The untouched first photo must still be available after saving the third.
        app.buttons["home.previousPhoto"].tap()
        XCTAssertTrue(app.buttons["home.photoExplanation"].firstMatch.label.contains("테스트 사진 1"))
        let keep = app.buttons["home.keepPhoto"]
        scrollToReveal(keep, in: app)
        keep.tap()
        XCTAssertEqual(counter.label, "1/1")
        XCTAssertTrue(app.buttons["home.photoExplanation"].firstMatch.label.contains("테스트 사진 2"))
        saveCurrentHomeRecord("Second photo saved last", in: app)
        XCTAssertTrue(app.staticTexts["home.completionTitle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["record.saved"].exists)
        XCTAssertFalse(app.buttons["record.done"].exists)
        XCTAssertFalse(counter.exists)
        app.buttons["리포트 탭"].tap()
        XCTAssertTrue(app.staticTexts["report.savedCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["report.savedCount"].label, "2개")
        XCTAssertEqual(app.staticTexts["report.deletedCount"].label, "0장")
        openSavedRecords(app)
        XCTAssertTrue(app.staticTexts["남긴 기록 3개"].waitForExistence(timeout: 5))
        for text in ["테스트로 남긴 기억", "Third photo saved first", "Second photo saved last"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists)
        }
    }

    func testIndependentReportRecordKeepsSavedPageAndExportActions() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-report-record", "-ui-testing-with-record"
        ])
        app.buttons["리포트 탭"].tap()
        let create = app.buttons["report.newRecord"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        scrollToReveal(create, in: app)
        create.tap()
        saveOpenRecord("Independent memory from Report", in: app)
        XCTAssertTrue(app.staticTexts["record.saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["공유하기"].exists)
        XCTAssertTrue(app.buttons["복사하기"].exists)
        XCTAssertFalse(app.buttons["record.save"].exists)
        let done = app.buttons["record.done"]
        scrollToReveal(done, in: app)
        XCTAssertEqual(done.label, "남긴 기록 보기")
        done.tap()
        XCTAssertTrue(app.staticTexts["남긴 기록 2개"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["테스트로 남긴 기억, 기록 자세히 보기"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Independent memory from Report")).firstMatch.exists)
        app.buttons["뒤로"].tap()
        XCTAssertTrue(app.staticTexts["report.savedCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["report.savedCount"].label, "1개")
        app.buttons["홈 탭"].tap()
        XCTAssertTrue(app.staticTexts["home.photoCounter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/3", "An independent record must not consume a Home recommendation")
    }

    func testReportKeepsNewSaveCountAfterLibraryAndTabReturns() {
        // Isolated simulator fixtures only: start with one stored record and
        // one corresponding weekly event before visiting Report.
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-with-record", "-ui-testing-with-record-activity"
        ])
        func visibleBack() -> Bool {
            let matches = app.buttons.matching(NSPredicate(format: "label == %@", "뒤로"))
                .allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertEqual(matches.count, 1, "Only the active screen's Back control may be tapped.")
            guard matches.count == 1, let back = matches.first else { return false }
            back.tap()
            return true
        }
        func assertReportCount(_ expected: Int) {
            let count = app.staticTexts["report.savedCount"]
            XCTAssertTrue(count.waitForExistence(timeout: 5))
            XCTAssertEqual(count.label, "\(expected)개")
            XCTAssertEqual(app.staticTexts["report.deletedCount"].label, "0장")
        }
        XCTAssertTrue(app.buttons["리포트 탭"].waitForExistence(timeout: 5))
        app.buttons["리포트 탭"].tap()
        assertReportCount(1)
        openSavedRecords(app)
        XCTAssertTrue(app.staticTexts["남긴 기록 1개"].waitForExistence(timeout: 5))
        let original = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "테스트로 남긴 기억")).firstMatch
        XCTAssertTrue(original.exists)
        guard visibleBack() else { return }
        assertReportCount(1)
        app.buttons["홈 탭"].tap()

        let record = app.buttons["기록하기"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        scrollToReveal(record, in: app)
        record.tap()
        let input = app.textViews["나의 한 줄"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let newText = "A second memory for report refresh"
        input.tap()
        input.typeText(newText)
        let keyboardDone = app.buttons["완료"]
        XCTAssertTrue(keyboardDone.isHittable)
        keyboardDone.tap()
        let preview = app.buttons["기록 미리보기"]
        scrollToReveal(preview, in: app)
        preview.tap()
        let save = app.buttons["record.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        scrollToReveal(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["home.photoCounter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/2")
        XCTAssertFalse(app.staticTexts["record.saved"].exists)
        XCTAssertFalse(app.buttons["record.done"].exists)
        app.buttons["리포트 탭"].tap()
        assertReportCount(2)
        openSavedRecords(app)

        XCTAssertTrue(app.staticTexts["남긴 기록 2개"].waitForExistence(timeout: 5),
                      "Direct navigation must include both the original and newly saved record.")
        XCTAssertTrue(original.exists)
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", newText)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
        scrollToReveal(saved, in: app)
        saved.tap()
        let detail = app.staticTexts["records.detailText"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertEqual(detail.label, newText)
        // Fixture photos are synthetic identifiers; this verifies the photo
        // surface, while real pixels require the separate physical screenshot.
        XCTAssertTrue(app.descendants(matching: .any)["records.detailPhoto"].firstMatch.exists)
        let savedShot = XCTAttachment(screenshot: app.screenshot())
        savedShot.name = "Second record detail with original record preserved"
        savedShot.lifetime = .keepAlways
        add(savedShot)
        guard visibleBack() else { return }
        XCTAssertTrue(app.staticTexts["남긴 기록 2개"].waitForExistence(timeout: 3))
        guard visibleBack() else { return }
        assertReportCount(2)

        openSavedRecords(app)
        XCTAssertTrue(app.staticTexts["남긴 기록 2개"].waitForExistence(timeout: 3))
        guard visibleBack() else { return }
        assertReportCount(2)
        app.buttons["홈 탭"].tap()
        XCTAssertTrue(app.buttons["기록하기"].waitForExistence(timeout: 5))
        app.buttons["리포트 탭"].tap()
        assertReportCount(2)
        let reportShot = XCTAttachment(screenshot: app.screenshot())
        reportShot.name = "Report keeps two saves after library and tab returns"
        reportShot.lifetime = .keepAlways
        add(reportShot)
    }

    func testLargeTextHomeKeepsActionsReachable() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        XCTAssertTrue(app.buttons["사진 비우기"].waitForExistence(timeout: 5))
        scrollToReveal(app.buttons["home.photoExplanation"].firstMatch, in: app)
        for title in ["사진 비우기", "기록하기", "그대로 두기"] {
            scrollToReveal(app.buttons[title], in: app)
            XCTAssertTrue(app.buttons[title].isHittable, title)
        }
        XCTAssertLessThanOrEqual(app.buttons["그대로 두기"].frame.maxY, app.buttons["홈 탭"].frame.minY)
    }

    func testNotificationSwitchHasAccessibleName() {
        let app = launch(route: "-ui-testing-route-main")
        app.buttons["마이페이지 탭"].tap()
        profileMenuRow(in: app, identifier: "profile.notifications", title: "알림 설정").tap()
        XCTAssertTrue(app.switches["정리 시간 알림"].waitForExistence(timeout: 3))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOnboardingSkipShowsFinalStartAndTerms() {
        let app = launch(route: "-ui-testing-route-onboarding")

        let skipButton = app.buttons["onboarding.skip"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: 3))
        skipButton.tap()

        XCTAssertEqual(app.buttons["onboarding.next"].label, "사진 정리 시작하기")
        // SwiftUI Link can be exposed as a Button when a ButtonStyle is applied.
        // Verify the actual legal controls, text, and touch target instead of its AX type.
        for (identifier, label) in [("onboarding.terms", "서비스 이용약관"),
                                    ("onboarding.privacy", "개인정보처리방침")] {
            let legal = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(legal.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertEqual(legal.label, label)
            scrollToReveal(legal, in: app)
            XCTAssertTrue(legal.isHittable)
            XCTAssertGreaterThanOrEqual(legal.frame.width, 44)
            XCTAssertGreaterThanOrEqual(legal.frame.height, 44)
        }
        XCTAssertFalse(app.buttons["auth.local"].exists)
    }

    func testPhotoPermissionNeutralNextOpensSystemChoiceAndRespectsDenial() {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["-ui-testing", "-ui-testing-reset", "-ui-testing-route-photo-permission"]
        app.launch()
        let next = app.buttons["photoPermission.request"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "다음")
        XCTAssertFalse(app.buttons["photoPermission.later"].exists)
        declinePhotoPermissionIfPresented(in: app)
        XCTAssertTrue(app.buttons["홈 탭"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.openPhotoSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.requestPhotoPermission"].exists)
        #else
        XCTFail("Permission reset is simulator-only; never modify a person's device permissions")
        #endif
    }

    func testEnglishPhotoPermissionUsesNeutralNextWithoutDeferral() {
        let app = launch(route: "-ui-testing-route-photo-permission", extraArguments: [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ])
        let next = app.buttons["photoPermission.request"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "Next")
        XCTAssertFalse(app.buttons["photoPermission.later"].exists)
        scrollToReveal(next, in: app)
        XCTAssertTrue(next.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Review fix - neutral Next opens the system photo choice"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testWeeklySummaryOpensReport() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel"])
        let weeklySummary = app.buttons["home.weeklySummary"]
        XCTAssertTrue(weeklySummary.waitForExistence(timeout: 5))
        weeklySummary.tap()
        XCTAssertTrue(app.staticTexts["이번 달 비운 사진"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["report.deletedCount"].exists)
        XCTAssertTrue(app.otherElements["report.calendar"].exists)
        XCTAssertFalse(app.buttons["report.openRecords"].exists)
        XCTAssertFalse(app.buttons["report.newRecord"].exists)
    }

    func testLocalProfileKeepsPhotoAccessManagementWithoutAccountActions() {
        let app = launch(route: "-ui-testing-route-main")

        let profileTab = app.buttons["마이페이지 탭"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 3))
        profileTab.tap()

        XCTAssertTrue(app.buttons["profile.login"].waitForExistence(timeout: 3),
                      "An optional account entry must not replace photo access management")
        XCTAssertFalse(app.buttons["회원탈퇴"].exists)
        XCTAssertFalse(app.buttons["로그아웃"].exists)
        assertProfileMenuStatuses(in: app)
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "Profile menu exposes current access notification and privacy status"
        overview.lifetime = .keepAlways; add(overview)
        let photoAccess = profileMenuRow(in: app, identifier: "profile.photoAccess", title: "사진 접근 관리")
        scrollToReveal(photoAccess, in: app)
        photoAccess.tap()
        let accessHeader = app.navigationBars["사진 접근 관리"]
        XCTAssertTrue(accessHeader.waitForExistence(timeout: 3))
        let accessScreen = XCTAttachment(screenshot: app.screenshot())
        accessScreen.name = "Photo access management opened without changing permission"
        accessScreen.lifetime = .keepAlways; add(accessScreen)
        let back = accessHeader.buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(photoAccess.waitForExistence(timeout: 3))
        XCTAssertFalse(accessHeader.exists)
        assertProfileMenuStatuses(in: app)
    }

    func testInstalledProfileAndCalendarReadOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RECOCO_VERIFY_INSTALLED_APP"] == "1",
                          "Opt in explicitly to inspect the installed app without resetting its data.")
        // Never call launch(route:) here: that helper resets and seeds the store.
        // These ordinary launch settings preserve the installed app's session,
        // records, cleanup history, and Photos permission.
        let app = XCUIApplication(bundleIdentifier: "app.recoco.ios.photonativetest")
        app.launchArguments = []
        app.launchEnvironment = [:]
        if app.state == .notRunning { app.launch() }
        else { app.activate() }

        let profileTab = app.buttons["마이페이지 탭"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15),
                      "The installed app must already allow entry; this test does not grant permissions or finish onboarding.")
        profileTab.tap()
        assertProfileMenuStatuses(in: app)
        let profile = XCTAttachment(screenshot: app.screenshot())
        profile.name = "Installed app profile status without changing settings"
        profile.lifetime = .keepAlways; add(profile)

        app.buttons["리포트 탭"].tap()
        XCTAssertTrue(app.otherElements["report.calendar"].waitForExistence(timeout: 5))
        returnCalendarToCurrentMonth(in: app)
        let current = XCTAttachment(screenshot: app.screenshot())
        current.name = "Installed app current month report"
        current.lifetime = .keepAlways; add(current)
        assertCleanupCalendarExploration(in: app, screenshotName: "Installed app past month and selected day")
        app.buttons["홈 탭"].tap()
        XCTAssertTrue(app.buttons["마이페이지 탭"].isHittable)
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "Installed app returned home without saving or deleting"
        home.lifetime = .keepAlways; add(home)
    }

    func testInstalledHomePreviewReadOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RECOCO_VERIFY_INSTALLED_APP"] == "1",
                          "Explicit opt-in is required to inspect the installed app with its existing data.")
        // Do not use launch(route:), reset authorization, seed fixtures, change
        // checkboxes, or tap cleanup. This test only browses the installed app.
        let app = XCUIApplication(bundleIdentifier: "app.recoco.ios.photonativetest")
        app.launchArguments = []
        app.launchEnvironment = [:]
        if app.state == .notRunning { app.launch() }
        else { app.activate() }

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func reportUnavailable(_ reason: String) {
            capture("Installed Home unavailable — \(reason)")
            let status = ["home.scanStatusTitle", "home.previewUnavailable", "home.cleanupFailureTitle"]
                .compactMap { identifier -> String? in
                    let text = app.staticTexts[identifier]
                    return text.exists ? text.label : nil
                }.joined(separator: " / ")
            XCTFail("\(reason). Visible status: \(status.isEmpty ? "No completed photo preview" : status). No permission or data changes were made.")
        }

        let homeTab = app.buttons["홈 탭"]
        guard homeTab.waitForExistence(timeout: 15) else {
            reportUnavailable("Installed app did not reach its existing Home session")
            return
        }
        homeTab.tap()
        let counter = app.staticTexts["home.photoCounter"]
        let carousel = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        guard counter.waitForExistence(timeout: 60), carousel.exists else {
            reportUnavailable("No real-photo recommendation carousel appeared")
            return
        }
        let position = counter.label.split(separator: "/").compactMap { Int($0) }
        guard position.count == 2, position[0] > 0, position[0] <= position[1], position[1] <= 3 else {
            reportUnavailable("Unexpected recommendation position: \(counter.label)")
            return
        }
        let initialPage = position[0], total = position[1]
        let select = app.buttons["home.selectPhoto"]
        let clear = app.buttons["home.deleteSelected"]
        guard select.exists, clear.exists else {
            reportUnavailable("Home decision controls are missing")
            return
        }
        let initialCountLabel = clear.label
        let initialCheck = select.value as? String
        let initialClearedCount = app.staticTexts["home.clearedCount"].label
        let selectedPhotos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.selectedPhoto."))
        let initialSelectedIDs = selectedPhotos.allElementsBoundByIndex.map(\.identifier).sorted()

        func assertSelectionUnchanged() {
            XCTAssertEqual(clear.label, initialCountLabel, "Browsing must preserve the pending deletion count")
            XCTAssertEqual(selectedPhotos.allElementsBoundByIndex.map(\.identifier).sorted(), initialSelectedIDs,
                           "Browsing must preserve every existing checkbox identity")
            XCTAssertEqual(app.staticTexts["home.clearedCount"].label, initialClearedCount,
                           "Viewing a photograph is not a deletion")
            if initialSelectedIDs.isEmpty {
                XCTAssertFalse(clear.isEnabled, "No selected photos means cleanup must remain disabled")
            }
        }
        func awaitVisiblePhoto(_ page: Int) -> XCUIElement? {
            // This overlay is created only after the main PHAsset image renders.
            // With no test launch arguments, bundled fixture images are bypassed.
            let photo = app.buttons["사진 \(page), 크게 보기"]
            guard photo.waitForExistence(timeout: 35) else {
                reportUnavailable("Real photo \(page)/\(total) failed to render")
                return nil
            }
            scrollToReveal(carousel, in: app)
            guard photo.isHittable else {
                reportUnavailable("Rendered photo \(page)/\(total) cannot open its viewer")
                return nil
            }
            return photo
        }

        guard let initialPhoto = awaitVisiblePhoto(initialPage) else { return }
        assertSelectionUnchanged()
        capture("Installed real-photo Home before read-only browsing")
        initialPhoto.tap()
        let back = app.buttons["뒤로"].firstMatch
        guard app.staticTexts["사진 보기"].waitForExistence(timeout: 5), back.exists, back.isHittable else {
            reportUnavailable("Photo viewer did not open with an accessible Back action")
            return
        }
        capture("Installed real photo opened without selecting or deleting")
        back.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "\(initialPage)/\(total)")
        assertSelectionUnchanged()

        var currentPage = initialPage
        for target in Array(1...total) + [initialPage] {
            while currentPage != target {
                scrollToReveal(carousel, in: app)
                if currentPage < target { carousel.swipeLeft(); currentPage += 1 }
                else { carousel.swipeRight(); currentPage -= 1 }
                let expected = "\(currentPage)/\(total)"
                expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: counter)
                waitForExpectations(timeout: 5)
                guard awaitVisiblePhoto(currentPage) != nil else { return }
                assertSelectionUnchanged()
            }
        }
        XCTAssertEqual(counter.label, "\(initialPage)/\(total)")
        XCTAssertEqual(select.value as? String, initialCheck)
        capture("Installed Home after swipes — existing selection and counts preserved")
    }

    func testSavedRecordAppearsInReportWithExportActions() {
        let app = launch(
            route: "-ui-testing-route-main",
            extraArguments: ["-ui-testing-with-record"]
        )

        app.buttons["리포트 탭"].tap()

        openSavedRecords(app)
        let memory = app.buttons["테스트로 남긴 기억, 기록 자세히 보기"]
        XCTAssertTrue(memory.waitForExistence(timeout: 3))
        memory.tap()
        XCTAssertTrue(app.staticTexts["테스트로 남긴 기억"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["공유하기"].exists)
        XCTAssertTrue(app.buttons["복사하기"].exists)
        scrollToReveal(app.buttons["기록 삭제"], in: app)
        app.buttons["기록 삭제"].tap()
        XCTAssertTrue(app.alerts["이 기록을 삭제할까요?"].waitForExistence(timeout: 3))
        app.alerts.buttons["취소"].tap()
        XCTAssertTrue(app.staticTexts["테스트로 남긴 기억"].exists)
    }

    func testKeepPhotoAdvancesWithoutDeletingOrCreatingRecord() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel"])
        let keep = app.buttons["home.keepPhoto"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertTrue(keep.isHittable)
        XCTAssertFalse(app.buttons["다른 사진으로 기록하기"].exists)
        keep.tap()
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "테스트 사진 2"), evaluatedWith: explanation)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
        app.buttons["리포트 탭"].tap()
        openSavedRecords(app)
        XCTAssertTrue(app.staticTexts["남긴 기록 0개"].waitForExistence(timeout: 3))
    }

    func testThreePendingPhotosOfferLimitedAccessPickerWithoutChangingSelection() {
        for isLimited in [true, false] {
            var arguments = ["-ui-testing-home-batch", "-ui-testing-preview-preselected", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
            if isLimited { arguments.append("-ui-testing-limited-access") }
            let app = launch(route: "-ui-testing-route-main", extraArguments: arguments)
            let counter = app.staticTexts["home.photoCounter"]
            XCTAssertTrue(counter.waitForExistence(timeout: 6))
            XCTAssertEqual(counter.label, "1/3")
            let selection = app.buttons["home.deleteSelected"]
            XCTAssertEqual(selection.label, "선택한 1장 비우기")
            let more = app.buttons["home.selectMorePhotos"]
            if isLimited {
                guard more.waitForExistence(timeout: 3) else {
                    return XCTFail("A full limited-access queue must still offer the Photos selection action.")
                }
                let scrollView = app.scrollViews.firstMatch
                if !more.isHittable && scrollView.exists {
                    scrollView.swipeUp()
                }
                XCTAssertTrue(more.isHittable, "button \(more.frame), tab \(app.buttons["tab.home"].frame), app \(app.frame)")
                XCTAssertEqual(more.label, "사진 더 선택하기")
                XCTAssertGreaterThanOrEqual(more.frame.height, 44)
            } else {
                XCTAssertFalse(more.exists)
            }
            XCTAssertEqual(selection.label, "선택한 1장 비우기")
            XCTAssertEqual(counter.label, "1/3")
            app.terminate()
        }
    }

    func testHomeCarouselSwipesWithoutClearingPhotos() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-batch"])
        let counter = app.staticTexts["home.photoCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let photo = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        let next = app.buttons["home.nextPhoto"]
        let previous = app.buttons["home.previousPhoto"]
        let initialTotal = app.staticTexts["home.clearedCount"].label

        func waitForPage(_ label: String) {
            expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: counter)
            waitForExpectations(timeout: 4)
        }
        waitForPage("1/3")
        XCTAssertFalse(previous.exists)
        XCTAssertTrue(next.isHittable)
        XCTAssertGreaterThanOrEqual(next.frame.width, 44)
        XCTAssertGreaterThanOrEqual(next.frame.height, 44)
        XCTAssertEqual(next.frame.midY, photo.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(next.frame.maxX, photo.frame.maxX + 1)

        photo.swipeLeft()
        waitForPage("2/3")
        previous.tap()
        waitForPage("1/3")
        next.tap()
        waitForPage("2/3")
        next.tap()
        waitForPage("3/3")
        XCTAssertFalse(next.exists)
        photo.swipeRight()
        waitForPage("2/3")
        XCTAssertEqual(app.buttons["home.selectPhoto"].value as? String, "선택 안 됨")
        XCTAssertFalse(app.buttons["home.deleteSelected"].isEnabled)
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, initialTotal)
    }

    func testMixedCarouselUsesUnifiedPhotoUIAndKeepsDisclosureInSync() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-mixed-reflection"])
        let counter = app.staticTexts["home.photoCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let reason = app.staticTexts["home.curationReason"]
        XCTAssertEqual(reason.label, "가까운 시간에 찍은 비슷한 사진이 있어요.")
        assertNoPhotoCategoryText(app)
        XCTAssertTrue(app.buttons["사진 비우기"].exists)
        XCTAssertTrue(app.buttons["사진 1, 크게 보기"].exists)
        XCTAssertFalse(app.buttons["비울 후보 1, 크게 보기"].exists)
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        XCTAssertTrue(explanation.label.contains("고른 이유"))
        explanation.tap()
        XCTAssertEqual(explanation.value as? String, "펼쳐짐")
        XCTAssertTrue(app.staticTexts["home.evidenceDetail"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["이 사진을 고른 이유"].exists)
        assertNoPhotoCategoryText(app)
        explanation.tap()
        let photo = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        photo.swipeLeft()
        expectation(for: NSPredicate(format: "label == %@", "2/3"), evaluatedWith: counter)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["사진 비우기"].exists)
        XCTAssertEqual(reason.label, "다시 살펴볼 사진을 골랐어요.")
        assertNoPhotoCategoryText(app)
        XCTAssertFalse(app.buttons["비울 후보 2, 크게 보기"].exists)
        XCTAssertTrue(app.buttons["사진 2, 크게 보기"].exists)
        XCTAssertTrue(app.buttons["기록하기"].isHittable)
        XCTAssertEqual(explanation.value as? String, "접힘")
        XCTAssertTrue(explanation.label.contains("고른 이유"))
        explanation.tap()
        XCTAssertTrue(app.staticTexts["home.evidenceDetail"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["home.photoCaption"].exists, "A display-only description is not capture-date metadata")
        XCTAssertFalse(app.staticTexts["home.photoDescription"].exists)
        XCTAssertFalse(app.staticTexts["테스트 사진 2"].exists)
        XCTAssertFalse(app.staticTexts["이 사진을 고른 이유"].exists)
        assertNoPhotoCategoryText(app)
        explanation.tap()
        app.buttons["사진 2, 크게 보기"].tap()
        XCTAssertTrue(app.staticTexts["사진 보기"].waitForExistence(timeout: 3))
        assertNoPhotoCategoryText(app)
        app.buttons["뒤로"].tap()
        photo.swipeRight()
        expectation(for: NSPredicate(format: "label == %@", "1/3"), evaluatedWith: counter)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["사진 비우기"].exists)
        XCTAssertEqual(reason.label, "가까운 시간에 찍은 비슷한 사진이 있어요.")
        XCTAssertEqual(explanation.value as? String, "접힘")
        assertNoPhotoCategoryText(app)
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
    }

    func testRecentSelectionHeadlineAndDetailStayConsistentWhenSwipingBothWays() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-recent-selection"
        ])
        let reason = app.staticTexts["home.curationReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        let counter = app.staticTexts["home.photoCounter"]
        let photo = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        let explanation = app.buttons["home.photoExplanation"].firstMatch

        func assertSelectedPhoto(_ index: Int) {
            expectation(for: NSPredicate(format: "label == %@", "\(index)/3"), evaluatedWith: counter)
            waitForExpectations(timeout: 3)
            XCTAssertEqual(reason.label, "최근 사진부터 골랐어요.")
            XCTAssertLessThanOrEqual(reason.frame.maxY, photo.frame.minY)
            XCTAssertTrue(app.buttons["사진 \(index), 크게 보기"].exists)
            XCTAssertEqual(explanation.value as? String, "접힘")
            XCTAssertTrue(explanation.label.contains("고른 이유"))
            assertPhotoActionPair(app)
            explanation.tap()
            let detail = app.staticTexts["home.evidenceDetail"]
            XCTAssertTrue(detail.waitForExistence(timeout: 3))
            XCTAssertEqual(detail.label, "허용한 사진 중 최근 사진부터 골랐어요.")
            XCTAssertEqual(reason.label, "최근 사진부터 골랐어요.")
            explanation.tap()
        }

        assertSelectedPhoto(1)
        photo.swipeLeft()
        assertSelectedPhoto(2)
        photo.swipeRight()
        assertSelectedPhoto(1)
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
    }

    func testExactDuplicateUsesFactualHeadingAndRetainsComparisonDisclosure() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-exact-duplicate", "-ui-testing-curation-comparison"
        ])
        let reason = app.staticTexts["home.curationReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        XCTAssertEqual(reason.label, "같은 사진이 한 장 더 있어요.")
        assertNoPhotoCategoryText(app)
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        XCTAssertTrue(explanation.label.contains("남길 사진과 비교"))
        explanation.tap()
        XCTAssertTrue(app.buttons["남길 사진, 크게 보기"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["비울 후보, 크게 보기"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts["home.evidenceDetail"].label, "같은 사진이 한 장 더 있어요.")
        XCTAssertFalse(app.staticTexts["이 사진을 고른 이유"].exists)
        assertNoPhotoCategoryText(app)
        explanation.tap()
        let clear = app.buttons["사진 비우기"]
        scrollToReveal(clear, in: app); clear.tap()
        XCTAssertTrue(app.staticTexts["이 사진을 비울까요?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["같은 사진이 한 장 더 있어요."].exists)
        assertNoPhotoCategoryText(app)
        app.buttons["취소"].tap()
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/3")
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
    }

    func testUnifiedPhotoDisclosureAndDeletionCancellationRemainReachableAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-mixed-reflection", "-ui-testing-delete-cancel",
            "-photo-context-testing=complete",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let second = app.buttons["home.nextPhoto"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        scrollToReveal(second, in: app); second.tap()
        XCTAssertEqual(app.staticTexts["home.curationReason"].label, "다시 살펴볼 사진을 골랐어요.")
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        scrollToReveal(explanation, in: app); explanation.tap()
        XCTAssertEqual(explanation.value as? String, "펼쳐짐")
        let caption = app.staticTexts["home.photoCaption"]
        scrollToReveal(caption, in: app)
        XCTAssertTrue(caption.isHittable)
        XCTAssertEqual(caption.label, expectedCaptureDate(daysAgo: 2) + " · 부산 해운대구 인근")
        XCTAssertFalse(app.staticTexts["home.photoDescription"].exists)
        assertNoPhotoCategoryText(app)
        for title in ["기록하기", "사진 비우기", "그대로 두기"] {
            let action = app.buttons[title]
            scrollToReveal(action, in: app)
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            XCTAssertLessThanOrEqual(action.frame.maxY, app.buttons["홈 탭"].frame.minY)
        }
        app.buttons["사진 비우기"].tap()
        XCTAssertTrue(app.staticTexts["이 사진을 비울까요?"].waitForExistence(timeout: 3))
        assertNoPhotoCategoryText(app)
        let clear = app.buttons["비우기"]
        scrollToReveal(clear, in: app)
        XCTAssertTrue(clear.isHittable)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        clear.tap()
        XCTAssertTrue(app.staticTexts["deletion.cancelled"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["deletion.success"].exists)
        let cancel = app.buttons["취소"]
        scrollToReveal(cancel, in: app)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Unified photo deletion cancellation at accessibility text size"
        shot.lifetime = .keepAlways; add(shot)
        cancel.tap()
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "2/3")
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
        assertNoPhotoCategoryText(app)
    }

    func testAnniversaryShowsActualCaptureDateAndNearbyPlaceWithoutChangingActions() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-anniversary", "-photo-context-testing=complete"])
        let reason = app.staticTexts["home.curationReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        XCTAssertEqual(reason.label, "지난해 이맘때 찍은 사진이에요.")
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        XCTAssertTrue(explanation.label.contains("고른 이유"))
        explanation.tap()
        let caption = app.staticTexts["home.photoCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "label == %@", expectedCaptureDate(yearsAgo: 1) + " · 서울 마포구 인근"), evaluatedWith: caption)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(app.staticTexts["home.evidenceDetail"].label, "지난해 같은 날짜에서 앞뒤 7일 안에 찍은 사진이에요.")
        XCTAssertFalse(app.staticTexts["home.photoDescription"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "home.photoCaption").count, 1)
        assertNoPhotoCategoryText(app)
        assertPhotoActionPair(app)
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
    }

    func testMissingPhotoContextOmitsCaptionAndKeepsActionsAvailable() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-carousel", "-ui-testing-mixed-reflection", "-photo-context-testing=missing"
        ])
        let second = app.buttons["home.nextPhoto"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        app.buttons["home.photoExplanation"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["home.evidenceDetail"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["home.photoCaption"].exists)
        XCTAssertFalse(app.staticTexts["테스트 사진 2"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "인근")).firstMatch.exists)
        XCTAssertEqual(app.activityIndicators.count, 0)
        XCTAssertEqual(app.alerts.count, 0)
        assertPhotoActionPair(app)
        assertNoPhotoCategoryText(app)
    }

    func testOfflinePhotoContextRetainsActualDateAndOmitsPlace() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-anniversary", "-photo-context-testing=offline"])
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        explanation.tap()
        let caption = app.staticTexts["home.photoCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 3))
        XCTAssertEqual(caption.label, expectedCaptureDate(yearsAgo: 1))
        XCTAssertFalse(caption.label.contains("인근"))
        XCTAssertFalse(caption.label.contains("·"))
        XCTAssertEqual(app.activityIndicators.count, 0)
        XCTAssertEqual(app.alerts.count, 0)
        assertPhotoActionPair(app)
        assertNoPhotoCategoryText(app)
    }

    func testDelayedPhotoContextDoesNotFollowThePreviousCarouselPhoto() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-anniversary", "-photo-context-testing=complete", "-photo-context-delay-first"
        ])
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        explanation.tap()
        XCTAssertTrue(app.staticTexts["home.photoCaption"].waitForExistence(timeout: 3))
        explanation.tap()
        let photo = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        photo.swipeLeft()
        let counter = app.staticTexts["home.photoCounter"]
        expectation(for: NSPredicate(format: "label == %@", "2/3"), evaluatedWith: counter)
        waitForExpectations(timeout: 3)
        explanation.tap()
        let caption = app.staticTexts["home.photoCaption"]
        expectation(for: NSPredicate(format: "label == %@", expectedCaptureDate(daysAgo: 2) + " · 부산 해운대구 인근"), evaluatedWith: caption)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(app.staticTexts["home.curationReason"].label, "다시 살펴볼 사진을 골랐어요.")
        XCTAssertFalse(caption.label.contains("서울"))
        explanation.tap()
        photo.swipeLeft()
        expectation(for: NSPredicate(format: "label == %@", "3/3"), evaluatedWith: counter)
        waitForExpectations(timeout: 3)
        explanation.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 3))
        XCTAssertEqual(caption.label, expectedCaptureDate(daysAgo: 3))
        XCTAssertFalse(caption.label.contains("부산"))
        XCTAssertFalse(caption.label.contains("서울"))
        explanation.tap()
        photo.swipeRight()
        expectation(for: NSPredicate(format: "label == %@", "2/3"), evaluatedWith: counter)
        waitForExpectations(timeout: 3)
        explanation.tap()
        expectation(for: NSPredicate(format: "label == %@", expectedCaptureDate(daysAgo: 2) + " · 부산 해운대구 인근"), evaluatedWith: caption)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
        assertNoPhotoCategoryText(app)
    }

    func testCurationShowsReferenceInHomeAndDeleteConfirmation() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-curation-comparison"])
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.isHittable, "Details are available before scrolling")
        XCTAssertTrue(explanation.label.contains("두 사진 비교"))
        explanation.tap()
        let reference = app.buttons["남길 사진, 크게 보기"].firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["비울 후보, 크게 보기"].firstMatch.exists)
        let evidence = app.staticTexts["home.evidenceDetail"]
        XCTAssertTrue(evidence.exists)
        XCTAssertGreaterThan(reference.frame.minY, evidence.frame.maxY)
        reference.tap()
        XCTAssertTrue(app.staticTexts["남길 사진"].waitForExistence(timeout: 3))
        app.buttons["뒤로"].tap()
        let candidate = app.buttons["비울 후보, 크게 보기"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 3))
        candidate.tap()
        XCTAssertTrue(app.staticTexts["비울 후보"].waitForExistence(timeout: 3))
        app.buttons["뒤로"].tap()
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        explanation.tap()
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        XCTAssertFalse(reference.exists)
        XCTAssertEqual(explanation.value as? String, "접힘")
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/3")
        let delete = app.buttons["사진 비우기"]
        if !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        XCTAssertTrue(app.staticTexts["이 사진을 비울까요?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["남길 사진, 크게 보기"].firstMatch.exists)
        app.buttons["취소"].tap()
        XCTAssertFalse(app.staticTexts["이 사진을 비울까요?"].exists)
    }

    func testContextualReasonAndDescriptionExpandAndFollowCarouselSelection() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-curation-context"])
        let reason = app.staticTexts["home.curationReason"]
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.isHittable)
        XCTAssertEqual(reason.label, "화면에서 읽은 기한이 지났어요.")
        XCTAssertTrue(explanation.label.contains("고른 이유"))
        XCTAssertTrue(explanation.label.contains("기한이 표시된 스크린샷"))
        XCTAssertFalse(app.staticTexts["화면의 사용 기한이 지났어요. 날짜가 맞는지 확인해주세요."].exists)
        explanation.tap()
        XCTAssertTrue(app.staticTexts["화면의 사용 기한이 지났어요. 날짜가 맞는지 확인해주세요."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["이 사진을 고른 이유"].exists)
        assertNoPhotoCategoryText(app)
        XCTAssertLessThan(app.staticTexts["home.evidenceDetail"].frame.minY, app.staticTexts["home.photoDescription"].frame.minY)
        explanation.tap()
        let second = app.buttons["home.nextPhoto"]
        if !second.isHittable { app.swipeUp() }
        second.tap()
        XCTAssertEqual(reason.label, "구매·배송 관련 문구가 보여요.")
        XCTAssertTrue(explanation.label.contains("고른 이유"))
        XCTAssertTrue(explanation.label.contains("구매·배송을 참고한 스크린샷"))
        explanation.tap()
        XCTAssertTrue(app.staticTexts["home.evidenceDetail"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["화면의 사용 기한이 지났어요. 날짜가 맞는지 확인해주세요."].exists)
        assertNoPhotoCategoryText(app)
        explanation.tap()
        let delete = app.buttons["사진 비우기"]
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        XCTAssertTrue(app.staticTexts["이 사진을 비울까요?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["구매·배송 관련 문구가 보여요."].exists)
        assertNoPhotoCategoryText(app)
        app.buttons["취소"].tap()
    }

    func testReviewDateDefersOnlySelectedPhotoWithoutCountingDeletion() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-curation-context"])
        let explanation = app.buttons["home.photoExplanation"].firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.isHittable)
        explanation.tap()
        let reviewDate = app.buttons["다시 확인할 날짜 정하기"]
        if !reviewDate.isHittable { app.swipeUp() }
        reviewDate.tap()
        app.buttons["7일 뒤 다시 확인"].tap()
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        XCTAssertTrue(explanation.label.contains("구매·배송을 참고한 스크린샷"))
        XCTAssertFalse(app.buttons["home.collapseExplanation"].exists)
        XCTAssertEqual(explanation.value as? String, "접힘")
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/2")
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, "사진 0장 비웠어요")
    }

    // Separate the one-screen layout contract from gesture behavior so a layout
    // failure does not prevent the carousel interaction assertions from running.
    func testHomeInitialActionsStayAboveTabBar() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel"])
        XCTAssertTrue(app.buttons["그대로 두기"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home default text initial layout"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        assertHomeLayout(app)
    }

    func testHomeShortTitleKeepsPhotoAndActionsInPlace() {
        let longTitleApp = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel"])
        XCTAssertTrue(longTitleApp.staticTexts["home.curationReason"].waitForExistence(timeout: 5))
        let twoLineTitle = longTitleApp.staticTexts["home.curationReason"].frame
        let photoTop = longTitleApp.descendants(matching: .any)["home.photoCarousel"].firstMatch.frame.minY
        XCTAssertGreaterThan(twoLineTitle.height, 30)
        assertHomeLayout(longTitleApp)

        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel", "-ui-testing-home-short-reason"])
        XCTAssertTrue(app.staticTexts["home.curationReason"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.curationReason"].label, "중복 사진이에요.")
        XCTAssertLessThan(app.staticTexts["home.curationReason"].frame.height, 30)
        XCTAssertEqual(app.descendants(matching: .any)["home.photoCarousel"].firstMatch.frame.minY, photoTop, accuracy: 1)
        assertHomeLayout(app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home one-line title web v32 metrics"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHomeDecisionsFollowExpandedExplanationAndReturnWhenCollapsed() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel"])
        let clear = app.buttons["사진 비우기"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        let collapsedY = clear.frame.minY
        let explanation = app.buttons["home.photoExplanation"]
        scrollToReveal(explanation, in: app)
        explanation.tap()
        XCTAssertEqual(explanation.value as? String, "펼쳐짐")
        XCTAssertGreaterThan(clear.frame.minY, collapsedY + 80)
        scrollToReveal(clear, in: app)
        let review = app.buttons["다시 확인할 날짜 정하기"]
        XCTAssertTrue(review.exists)
        XCTAssertGreaterThan(clear.frame.minY, review.frame.maxY)
        XCTAssertLessThanOrEqual(clear.frame.maxY, app.buttons["홈 탭"].frame.minY)
        XCTAssertTrue(app.buttons["기록하기"].isHittable)
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Decisions below expanded photo explanation"; expanded.lifetime = .keepAlways; add(expanded)

        for _ in 0..<8 {
            if explanation.isHittable { break }
            app.swipeDown()
        }
        explanation.tap()
        XCTAssertEqual(explanation.value as? String, "접힘")
        XCTAssertFalse(review.exists)
        for _ in 0..<8 {
            if app.buttons["home.weeklySummary"].isHittable { break }
            app.swipeDown()
        }
        // A final downward swipe reaches the original top, including any partial banner.
        app.swipeDown()
        XCTAssertEqual(clear.frame.minY, collapsedY, accuracy: 2)
        let collapsed = XCTAttachment(screenshot: app.screenshot())
        collapsed.name = "Collapsed Home returns to its original content position"
        collapsed.lifetime = .keepAlways
        add(collapsed)
        // A square photo and the actions share a scroll flow on short screens.
        // Keep the geometry contract, then prove every action clears the tab bar.
        assertHomeLayout(app, scrollActionsIntoView: true)
    }

    func testUnscannedEmptyHomeShowsOneNextStepAndOneAlternative() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-first-scan", "-ui-testing-first-scan-limited", "-ui-testing-first-scan-more"
        ])
        let title = app.staticTexts["home.scanStatusTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "아직 정리할 사진을 찾지 못했어요.")
        let next = app.buttons["home.morePhotos"]
        let select = app.buttons["home.selectMorePhotos"]
        XCTAssertEqual(next.label, "이어서 찾아보기")
        XCTAssertTrue(next.isHittable)
        XCTAssertTrue(select.isHittable)
        XCTAssertFalse(app.buttons["home.openRecords"].exists)
        XCTAssertFalse(app.buttons["home.finishSession"].exists)
        XCTAssertFalse(app.staticTexts["home.completionTitle"].exists)
        XCTAssertGreaterThan(next.frame.minY, title.frame.maxY)
        XCTAssertLessThan(next.frame.minY - title.frame.maxY, 140)
        XCTAssertLessThanOrEqual(select.frame.maxY, app.buttons["홈 탭"].frame.minY)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Unscanned photos are an invitation to search, not promised recommendations"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testEmptyHomeActionsFollowContentAndSupportLargeText() {
        let empty = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-first-scan", "-ui-testing-first-scan-limited"])
        let select = empty.buttons["home.selectMorePhotos"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        XCTAssertTrue(empty.buttons["home.weeklySummary"].exists)
        XCTAssertGreaterThan(select.frame.minY, empty.staticTexts["home.scanStatusTitle"].frame.maxY)
        scrollToReveal(select, in: empty)
        XCTAssertGreaterThanOrEqual(select.frame.height, 44)
        XCTAssertLessThanOrEqual(select.frame.maxY, empty.buttons["홈 탭"].frame.minY)
        let shot = XCTAttachment(screenshot: empty.screenshot()); shot.name = "Empty Home actions follow content"; shot.lifetime = .keepAlways; add(shot)
        let large = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-first-scan", "-ui-testing-first-scan-limited",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let largeSelect = large.buttons["home.selectMorePhotos"]
        XCTAssertTrue(largeSelect.waitForExistence(timeout: 5))
        scrollToReveal(largeSelect, in: large)
        XCTAssertTrue(largeSelect.isHittable)
        let largeShot = XCTAttachment(screenshot: large.screenshot()); largeShot.name = "Empty Home at accessibility text size"; largeShot.lifetime = .keepAlways; add(largeShot)
    }

    func testHomeLargeTextKeepsActionsInReadingFlow() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-carousel",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        for title in ["사진 비우기", "기록하기", "그대로 두기"] {
            let button = app.buttons[title]
            scrollToReveal(button, in: app)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Large text scrolls content and actions together"; shot.lifetime = .keepAlways; add(shot)
    }

    private func assertHomeLayout(_ app: XCUIApplication, scrollActionsIntoView: Bool = false) {
        let carousel = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        XCTAssertEqual(carousel.frame.width, carousel.frame.height, accuracy: 1)
        XCTAssertEqual(carousel.frame.width, app.frame.width - 48, accuracy: 1)
        let record = app.buttons["기록하기"], clear = app.buttons["사진 비우기"]
        XCTAssertLessThan(record.frame.maxX, clear.frame.minX)
        XCTAssertEqual(clear.frame.width / record.frame.width, 1.6, accuracy: 0.03)
        XCTAssertEqual(record.frame.minY, clear.frame.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(record.frame.height, 52)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 52)
        for title in ["사진 비우기", "기록하기", "그대로 두기"] {
            if scrollActionsIntoView {
                scrollToReveal(app.buttons[title], in: app)
            }
            XCTAssertTrue(app.buttons[title].isHittable, title)
            XCTAssertGreaterThanOrEqual(app.buttons[title].frame.height, 44, title)
            XCTAssertLessThanOrEqual(app.buttons[title].frame.maxY + 8, app.buttons["홈 탭"].frame.minY, title)
        }
    }

    func testLargeTextOnboardingCanFinish() {
        let app = launch(route: "-ui-testing-route-onboarding", extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            scrollToReveal(next, in: app)
            XCTAssertTrue(next.isHittable)
            XCTAssertGreaterThanOrEqual(next.frame.height, 44)
            XCTAssertLessThanOrEqual(next.frame.maxY, app.frame.maxY)
            next.tap()
        }
        continueWithoutAccount(in: app)
        // Previously decided Photos permission skips education and opens Home.
        let needsPhotoAccess = app.buttons["photoPermission.request"].waitForExistence(timeout: 5)
        XCTAssertTrue(needsPhotoAccess || app.buttons["홈 탭"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(next.exists)
        XCTAssertFalse(app.buttons["auth.local"].exists)
    }

    func testCleanupOnboardingExplainsSelectionWithoutExtraComparison() {
        let app = launch(route: "-ui-testing-route-onboarding")
        let start = app.buttons["onboarding.next"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.staticTexts["오늘은 제가\n최대 세 장 골라볼게요."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["같은 사진이나 연달아 찍은\n비슷한 장면을 찾아요."].exists)
        XCTAssertTrue(app.staticTexts["“같은 사진이 한 장 더 있어요.”"].exists)
        XCTAssertFalse(app.buttons["onboarding.sampleComparison"].exists)
        XCTAssertFalse(app.buttons["auth.local"].exists)
        XCTAssertFalse(app.buttons["photoPermission.request"].exists)
        app.buttons["onboarding.skip"].tap()
        XCTAssertEqual(start.label, "사진 정리 시작하기")
        start.tap()
        continueWithoutAccount(in: app)
        // Previously decided Photos permission skips education and opens Home.
        let needsPhotoAccess = app.buttons["photoPermission.request"].waitForExistence(timeout: 5)
        XCTAssertTrue(needsPhotoAccess || app.buttons["홈 탭"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(start.exists)
        XCTAssertFalse(app.buttons["auth.local"].exists)
    }

    func testLargeTextPermissionNextRemainsReachable() {
        let app = launch(route: "-ui-testing-route-photo-permission", extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let next = app.buttons["photoPermission.request"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "다음")
        XCTAssertFalse(app.buttons["photoPermission.later"].exists)
        scrollToReveal(next, in: app)
        XCTAssertTrue(next.isHittable)
        XCTAssertTrue(app.frame.contains(next.frame), "The system-request action must remain visible at large text sizes")
    }

    func testSavedRecordEntryEntireRowIsTappable() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-with-record"])
        app.buttons["리포트 탭"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "기록 모아보기")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        scrollToReveal(entry, in: app)
        entry.tap() // The middle of the full-width CTA must respond, including its spacer.
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Saved records row after center tap"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.staticTexts["남긴 기록 1개"].waitForExistence(timeout: 3))
    }

    func testRecordLibrarySearchAndReturnPreserveContext() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-record-library"])
        app.buttons["리포트 탭"].tap()
        openSavedRecords(app)
        XCTAssertTrue(app.staticTexts["남긴 기록 80개"].waitForExistence(timeout: 5))
        let search = app.textFields["records.search"]
        search.tap()
        search.typeText("바다\n")
        XCTAssertTrue(app.staticTexts["검색 결과 27개 · 전체 80개"].waitForExistence(timeout: 3))
        let target = app.buttons["records.row.00000000-0000-0000-0000-000000000031"]
        scrollToReveal(target, in: app)
        let previousY = target.frame.minY
        target.tap()
        XCTAssertTrue(app.buttons["공유하기"].waitForExistence(timeout: 3))
        app.buttons["뒤로"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        XCTAssertTrue(target.isHittable)
        XCTAssertEqual(target.frame.minY, previousY, accuracy: 8)
        XCTAssertEqual(search.value as? String, "바다")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Record library after returning from detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["검색어 지우기"].tap()
        search.tap()
        search.typeText("없는단어\n")
        XCTAssertTrue(app.staticTexts["일치하는 기록이 없어요."].waitForExistence(timeout: 3))
        app.buttons["전체 기록 보기"].tap()
        XCTAssertTrue(app.staticTexts["남긴 기록 80개"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["최근 7일"].exists)
    }

    func testRecordLibrarySearchAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-record-library", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        app.buttons["리포트 탭"].tap()
        openSavedRecords(app)
        let search = app.textFields["records.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("없는단어\n")
        let clear = app.buttons["전체 기록 보기"]
        scrollToReveal(clear, in: app)
        clear.tap()
        XCTAssertTrue(app.staticTexts["남긴 기록 80개"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Record library at large text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testClusterSelectionHasReachableConfirmationAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-design-cluster", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let choose = app.buttons["다른 사진 고르기"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        let initialDeletedCount = app.staticTexts["home.clearedCount"].label
        scrollToReveal(choose, in: app); choose.tap()
        let confirm = app.buttons["photoSelection.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        let photo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "사진 2번")).firstMatch
        scrollToReveal(photo, in: app); photo.tap()
        XCTAssertTrue(photo.isSelected)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Photo selection at accessibility size"; shot.lifetime = .keepAlways; add(shot)
        confirm.tap()
        let confirmationTitle = app.staticTexts["이 사진들을 정리할까요?"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["정리할 사진 2장"].exists)
        let clear = app.buttons["사진 2장 비우기"]
        let cancel = app.buttons["취소"]
        // The title alone does not prove that a short sheet at large text can
        // reach its decisions. Inspect both controls without deleting fixtures.
        for control in [clear, cancel] {
            scrollToReveal(control, in: app)
            XCTAssertTrue(control.isHittable)
            XCTAssertTrue(control.isEnabled)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
        }
        let confirmationShot = XCTAttachment(screenshot: app.screenshot())
        confirmationShot.name = "Cluster confirmation actions at accessibility size"
        confirmationShot.lifetime = .keepAlways
        add(confirmationShot)
        cancel.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: confirmationTitle)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, initialDeletedCount)
        scrollToReveal(choose, in: app)
        XCTAssertTrue(choose.isHittable, "Cancellation returns to the same cluster without completing it")
        XCTAssertFalse(app.staticTexts["deletion.success"].exists)
    }

    func testFallbackPhotoUsesUnifiedHeadingAndFullPhotoContainer() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-design-recall"])
        let photo = app.buttons["사진 1, 크게 보기"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(photo.frame.width, app.frame.width - 50)
        XCTAssertEqual(app.staticTexts["home.curationReason"].label, "다시 살펴볼 사진을 골랐어요.")
        XCTAssertEqual(app.staticTexts["home.photoCounter"].label, "1/1")
        XCTAssertTrue(app.buttons["사진 비우기"].exists)
        assertNoPhotoCategoryText(app)
        XCTAssertFalse(app.buttons["비울 후보 1, 크게 보기"].exists)
        photo.tap()
        XCTAssertTrue(app.staticTexts["사진 보기"].waitForExistence(timeout: 5))
        assertNoPhotoCategoryText(app)
        app.buttons["뒤로"].tap()
        let keep = app.buttons["home.keepPhoto"]
        scrollToReveal(keep, in: app)
        XCTAssertTrue(keep.isHittable)
        XCTAssertTrue(app.buttons["기록하기"].isHittable)
    }

    private func saveCurrentHomeRecord(_ text: String, in app: XCUIApplication) {
        let record = app.buttons["기록하기"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        scrollToReveal(record, in: app)
        record.tap()
        saveOpenRecord(text, in: app)
    }

    private func saveOpenRecord(_ text: String, in app: XCUIApplication) {
        let input = app.textViews["나의 한 줄"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(text)
        let keyboardDone = app.buttons["완료"]
        XCTAssertTrue(keyboardDone.isHittable)
        keyboardDone.tap()
        let preview = app.buttons["기록 미리보기"]
        scrollToReveal(preview, in: app)
        preview.tap()
        let save = app.buttons["record.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        scrollToReveal(save, in: app)
        save.tap()
    }

    private func expectedCaptureDate(yearsAgo: Int = 0, daysAgo: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let yearAdjusted = calendar.date(byAdding: .year, value: -yearsAgo, to: Date())!
        let captured = calendar.date(byAdding: .day, value: -daysAgo, to: yearAdjusted)!
        let parts = calendar.dateComponents([.year, .month, .day], from: captured)
        return "\(parts.year!)년 \(parts.month!)월 \(parts.day!)일"
    }

    private func assertPhotoActionPair(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let record = app.buttons["기록하기"]
        let clear = app.buttons["사진 비우기"]
        scrollToReveal(record, in: app)
        scrollToReveal(clear, in: app)
        XCTAssertTrue(record.isHittable && record.isEnabled, file: file, line: line)
        XCTAssertTrue(clear.isHittable && clear.isEnabled, file: file, line: line)
        XCTAssertEqual(record.frame.minY, clear.frame.minY, accuracy: 1, file: file, line: line)
        XCTAssertLessThan(record.frame.maxX, clear.frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(clear.frame.maxY, app.buttons["홈 탭"].frame.minY, file: file, line: line)
    }

    private func assertNoPhotoCategoryText(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.staticTexts["home.curationPurpose"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["deletion.userChoice"].exists, file: file, line: line)
        for text in ["다시 살펴보기 · 삭제 추천 아님", "정리 추천", "필요 확인", "정리 후보", "오늘의 회상", "기억 돌아보기",
                     "삭제 추천이 아닌, 다시 살펴보도록 고른 사진이에요."] {
            XCTAssertFalse(app.staticTexts[text].exists, "Category text remains visible: \(text)", file: file, line: line)
        }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "기억 떠올리기")).firstMatch.exists,
                       "The disclosure uses the same neutral label for every photo", file: file, line: line)
    }

    private func openSavedRecords(_ app: XCUIApplication) {
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "기록 모아보기")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        scrollToReveal(entry, in: app)
        // Exercise the remaining journey via the visible label. The full-row
        // hit area is independently checked by testSavedRecordEntryEntireRowIsTappable.
        entry.staticTexts["기록 모아보기"].tap()
    }

    private func profileMenuRow(in app: XCUIApplication, identifier: String, title: String) -> XCUIElement {
        let identified = app.buttons[identifier]
        if identified.exists { return identified }
        // SwiftUI can merge a button's title and value in the AX snapshot.
        // Its native Button role and complete spoken status remain required.
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func assertProfileMenuStatuses(in app: XCUIApplication) {
        for (identifier, title) in [("profile.photoAccess", "사진 접근 관리"),
                                    ("profile.notifications", "알림 설정"),
                                    ("profile.privacy", "개인정보 안내")] {
            let row = profileMenuRow(in: app, identifier: identifier, title: title)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(identifier)\n\(app.debugDescription)")
            scrollToReveal(row, in: app)
            XCTAssertTrue(row.label.hasPrefix(title))
            let value = (row.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let combinedStatus = String(row.label.dropFirst(title.count))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            XCTAssertFalse(value.isEmpty && combinedStatus.isEmpty,
                           "VoiceOver must announce both the action and its status: \(identifier)")
            XCTAssertTrue(row.isHittable, identifier)
            XCTAssertGreaterThanOrEqual(row.frame.height + 0.01, 44, identifier)
            XCTAssertGreaterThanOrEqual(row.frame.width + 0.01, 44, identifier)
        }
    }

    private func returnCalendarToCurrentMonth(in app: XCUIApplication) {
        let next = app.buttons["report.calendar.nextMonth"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        // Calendar navigation changes presentation state only. Bounded recovery
        // also covers an installed app that was left viewing an earlier month.
        for _ in 0..<24 {
            scrollToReveal(next, in: app)
            if !next.isEnabled { break }
            next.tap()
        }
        XCTAssertFalse(next.isEnabled, "Calendar must finish on the current month")
        XCTAssertFalse(app.descendants(matching: .any)["report.calendar.monthSummary"].firstMatch.exists,
                       "The current month's total already appears above the calendar")
    }

    private func assertCleanupCalendarExploration(in app: XCUIApplication, screenshotName: String) {
        let month = app.staticTexts["report.calendar.month"]
        let monthSummary = app.descendants(matching: .any)["report.calendar.monthSummary"].firstMatch
        let daySummary = app.descendants(matching: .any)["report.calendar.daySummary"].firstMatch
        let previous = app.buttons["report.calendar.previousMonth"]
        let next = app.buttons["report.calendar.nextMonth"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["report.scroll"].waitForExistence(timeout: 5))
        let currentMonth = month.label
        XCTAssertFalse(monthSummary.exists, "Do not repeat the current month's total under the calendar")
        XCTAssertFalse(next.isEnabled)
        for (control, title) in [(previous, "이전 달"), (next, "다음 달")] {
            scrollToReveal(control, in: app)
            XCTAssertEqual(control.label, title)
            // Coordinate conversion can return 43.999999999999986 for 44pt.
            XCTAssertGreaterThanOrEqual(control.frame.height + 0.01, 44)
            XCTAssertGreaterThanOrEqual(control.frame.width + 0.01, 44)
        }
        previous.tap()
        XCTAssertNotEqual(month.label, currentMonth)
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(monthSummary.waitForExistence(timeout: 3))

        // At accessibility sizes the grid scrolls horizontally. Choose a fully
        // visible real day instead of tapping a clipped first-of-month cell.
        var selectedDay: XCUIElement?
        for _ in 0..<8 {
            selectedDay = visibleCalendarDays(in: app).first
            if selectedDay != nil { break }
            app.swipeUp()
        }
        guard let day = selectedDay else {
            XCTFail("No calendar day could be reached at the current text size\n\(app.debugDescription)")
            return
        }
        XCTAssertGreaterThanOrEqual(day.frame.width + 0.01, 44)
        XCTAssertGreaterThanOrEqual(day.frame.height + 0.01, 44)
        XCTAssertTrue(day.label.contains("년") && day.label.contains("일") && day.label.contains("장 비움"),
                      "A calendar day must announce its complete date and cleanup count")
        let dateParts = (day.label.components(separatedBy: ",").first ?? "").split(separator: " ")
        guard dateParts.count == 3 else {
            XCTFail("Calendar date is not clearly announced: \(day.label)")
            return
        }
        let dateLabel = "\(dateParts[1]) \(dateParts[2])"
        tapVisibleCalendarDay(day, in: app)
        assertCalendarResultVisible(daySummary, in: app)
        XCTAssertTrue(daySummary.isHittable)
        XCTAssertTrue(daySummary.label.contains(dateLabel), "The day card follows the selected date")
        XCTAssertTrue(daySummary.label.contains("비웠어요") || daySummary.label.contains("비운 사진이 없어요"))
        XCTAssertLessThanOrEqual(daySummary.frame.maxY, app.buttons["홈 탭"].frame.minY + 0.01,
                                 "The day card can scroll clear of the tab bar")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(day.isSelected, "VoiceOver must distinguish the selected day")

        scrollToReveal(next, in: app)
        next.tap()
        XCTAssertEqual(month.label, currentMonth)
        XCTAssertFalse(next.isEnabled)
        XCTAssertFalse(monthSummary.exists)
    }

    private func calendarVisibleBounds(in app: XCUIApplication) -> CGRect {
        let frame = app.scrollViews["report.scroll"].frame.intersection(app.frame)
        let bottom = min(frame.maxY, app.buttons["홈 탭"].frame.minY)
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                      height: max(0, bottom - frame.minY))
    }

    private func calendarFrameIsFullyVisible(_ frame: CGRect, in app: XCUIApplication) -> Bool {
        let bounds = calendarVisibleBounds(in: app)
        return frame.width > 0 && frame.height > 0 && bounds.height > 0
            && frame.minX >= bounds.minX - 0.5 && frame.maxX <= bounds.maxX + 0.5
            && frame.minY >= bounds.minY - 0.5 && frame.maxY <= bounds.maxY + 0.5
    }

    private func calendarResultIsFullyVisible(_ result: XCUIElement, in app: XCUIApplication) -> Bool {
        result.exists && calendarFrameIsFullyVisible(result.frame, in: app)
    }

    private func visibleCalendarDays(in app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label MATCHES %@",
            "report.calendar.day.", "[0-9]+년 [0-9]+월 [0-9]+일, 사진 [0-9]+장 비움"))
            .allElementsBoundByIndex.filter { day in
                day.isEnabled && calendarFrameIsFullyVisible(day.frame, in: app)
            }
    }

    private func tapVisibleCalendarDay(_ day: XCUIElement, in app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let frame = day.frame
        XCTAssertTrue(calendarFrameIsFullyVisible(frame, in: app),
                      "The date must be on screen before a literal finger tap", file: file, line: line)
        guard calendarFrameIsFullyVisible(frame, in: app) else { return }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
    }

    private func assertCalendarResultVisible(_ result: XCUIElement, in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let visible = NSPredicate { _, _ in self.calendarResultIsFullyVisible(result, in: app) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 5), .completed,
                       "Selecting a date must reveal the full result without an extra swipe or element-assisted scrolling",
                       file: file, line: line)
    }

    private func scrollToReveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            let bounds = app.frame
            let homeTab = app.buttons["tab.home"]
            let lowerEdge = homeTab.exists && homeTab.isHittable ? min(bounds.maxY, homeTab.frame.minY) : bounds.maxY
            let frame = element.frame
            // Use the actual viewport: SE has no 34pt home-indicator inset.
            // An exposed tab bar is an additional occluding boundary.
            if element.isHittable,
               frame.minX >= bounds.minX, frame.maxX <= bounds.maxX,
               frame.minY >= bounds.minY, frame.maxY <= lowerEdge { return }
            if frame.minY < bounds.minY { app.swipeDown() }
            else { app.swipeUp() }
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Unreachable control: \(element.label)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTFail("Control could not be fully revealed: \(element.label)")
    }

    func testCleanupBatchSelectionKeepsCountWhenRevisitingPhoto() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-batch"])
        let select = app.buttons["home.selectPhoto"]
        let clear = app.buttons["home.deleteSelected"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        scrollToReveal(select, in: app)
        XCTAssertFalse(clear.isEnabled)
        XCTAssertFalse(app.buttons["기록하기"].exists)
        select.tap()
        XCTAssertTrue(clear.label.contains("1장"))
        let firstCounter = app.staticTexts["home.photoCounter"].label
        let carousel = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        scrollToReveal(carousel, in: app)
        carousel.swipeLeft()
        XCTAssertNotEqual(app.staticTexts["home.photoCounter"].label, firstCounter)
        scrollToReveal(select, in: app)
        select.tap()
        XCTAssertTrue(clear.label.contains("2장"))
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.selectedPhoto."))
        XCTAssertEqual(previews.count, 2)
        let firstPreview = previews.element(boundBy: 0)
        scrollToReveal(firstPreview, in: app)
        XCTAssertGreaterThanOrEqual(firstPreview.frame.width, 44)
        XCTAssertGreaterThanOrEqual(firstPreview.frame.height, 44)
        firstPreview.tap()
        let returnedCounter = app.staticTexts["home.photoCounter"]
        let returnedToPhoto = NSPredicate { _, _ in
            let bounds = app.frame
            let lowerEdge = app.buttons["홈 탭"].frame.minY
            return returnedCounter.exists && carousel.exists && returnedCounter.isHittable
                && returnedCounter.frame.minY >= bounds.minY
                && returnedCounter.frame.maxY <= lowerEdge
                && carousel.frame.minY >= bounds.minY
                && carousel.frame.maxY <= lowerEdge
        }
        expectation(for: returnedToPhoto, evaluatedWith: returnedCounter)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(returnedCounter.label, firstCounter, "The selected thumbnail returns to its full photo")
        let returnedPhoto = XCTAttachment(screenshot: app.screenshot())
        returnedPhoto.name = "Selected thumbnail brings full carousel photo back into view"
        returnedPhoto.lifetime = .keepAlways; add(returnedPhoto)
        XCTAssertTrue(clear.label.contains("2장"), "Preview navigation does not alter selection")
        XCTAssertEqual(select.value as? String, "선택됨")
        scrollToReveal(select, in: app); select.tap()
        XCTAssertTrue(clear.label.contains("1장"))
        XCTAssertEqual(previews.count, 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cleanup carousel selection and selected-photo revisit"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testCleanupBatchNavigationKeepsSelectedPhotos() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-batch"])
        let select = app.buttons["home.selectPhoto"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        scrollToReveal(select, in: app); select.tap()
        XCTAssertFalse(app.buttons["home.finishReviewing"].exists)
        XCTAssertFalse(app.buttons["home.photoExplanation"].exists)
        app.buttons["리포트 탭"].tap()
        let deleted = app.staticTexts["report.deletedCount"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 5))
        XCTAssertEqual(deleted.label, "0장", "Leaving Home must not delete selected photos")
        app.buttons["홈 탭"].tap()
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        XCTAssertEqual(select.value as? String, "선택됨")
        XCTAssertTrue(app.buttons["home.deleteSelected"].label.contains("1장"))
    }

    func testCleanupBatchDeletionSuccessCountsOnlySelectedPhotos() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-batch", "-ui-testing-delete-success"
        ])
        let select = app.buttons["home.selectPhoto"]
        let clear = app.buttons["home.deleteSelected"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        scrollToReveal(select, in: app); select.tap()
        scrollToReveal(clear, in: app)
        XCTAssertTrue(clear.label.contains("1장"))
        clear.tap()
        let counter = app.staticTexts["home.photoCounter"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "/2"), evaluatedWith: counter)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(clear.isEnabled, "The remaining photos are not implicitly selected")
        let result = app.staticTexts["home.cleanupResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertEqual(result.label, "사진 1장을 비웠어요. 선택하지 않은 2장은 그대로예요.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.selectedPhoto.")).count, 0)
        app.buttons["마이페이지 탭"].tap()
        app.buttons["홈 탭"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5), "The result should not expire while the user reads it")
        scrollToReveal(select, in: app); select.tap()
        XCTAssertFalse(result.exists, "A new selection dismisses the previous outcome")
        app.buttons["리포트 탭"].tap()
        let deleted = app.staticTexts["report.deletedCount"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 5))
        XCTAssertEqual(deleted.label, "1장")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cleanup report after one selected photo was cleared"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testCleanupBatchDeletionCancellationKeepsPhotosAndSelection() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-batch", "-ui-testing-delete-cancel"
        ])
        let select = app.buttons["home.selectPhoto"]
        let clear = app.buttons["home.deleteSelected"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        let initialCount = app.staticTexts["home.clearedCount"].label
        scrollToReveal(select, in: app); select.tap()
        scrollToReveal(clear, in: app); clear.tap()
        XCTAssertTrue(app.staticTexts["비우기를 취소했어요. 선택한 사진은 그대로예요."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.clearedCount"].label, initialCount)
        XCTAssertTrue(app.staticTexts["home.photoCounter"].label.contains("/3"))
        XCTAssertEqual(select.value as? String, "선택됨")
        XCTAssertTrue(clear.isEnabled)
        XCTAssertTrue(clear.label.contains("1장"))
    }

    func testFailedHomePhotoCanRetryInlineBeforeSelectingAndDeleting() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-batch", "-ui-testing-preview-failure", "-ui-testing-delete-success"
        ])
        let retry = app.buttons["photo.retryLoad"]
        let select = app.buttons["home.selectPhoto"]
        let clear = app.buttons["home.deleteSelected"]
        let counter = app.staticTexts["home.photoCounter"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "A failed Home preview offers an inline retry")
        XCTAssertEqual(counter.label, "1/3")
        XCTAssertEqual(select.value as? String, "선택 안 됨")
        XCTAssertFalse(select.isEnabled, "An unseen photo cannot become a new deletion selection")
        XCTAssertFalse(clear.isEnabled)
        XCTAssertEqual(clear.label, "선택한 0장 비우기")

        scrollToReveal(retry, in: app)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        let blockedPreview = XCTAttachment(screenshot: app.screenshot())
        blockedPreview.name = "Failed photo blocks cleanup and offers inline retry"
        blockedPreview.lifetime = .keepAlways
        add(blockedPreview)
        retry.tap()
        expectation(for: NSPredicate { _, _ in select.exists && select.isEnabled }, evaluatedWith: select)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(select.value as? String, "선택 안 됨", "Retry never selects a photo for deletion")
        XCTAssertFalse(clear.isEnabled)
        XCTAssertEqual(counter.label, "1/3", "Retry keeps the same photo in the carousel")
        scrollToReveal(select, in: app)
        select.tap()
        XCTAssertEqual(clear.label, "선택한 1장 비우기")
        XCTAssertTrue(clear.isEnabled)
        scrollToReveal(clear, in: app)
        clear.tap()

        expectation(for: NSPredicate(format: "label CONTAINS %@", "/2"), evaluatedWith: counter)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["home.cleanupResult"].label,
                       "사진 1장을 비웠어요. 선택하지 않은 2장은 그대로예요.")
        XCTAssertEqual(clear.label, "선택한 0장 비우기")
        XCTAssertFalse(clear.isEnabled)
        app.buttons["리포트 탭"].tap()
        let deleted = app.staticTexts["report.deletedCount"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 5))
        XCTAssertEqual(deleted.label, "1장", "Only the explicitly selected photo is counted after retry")
    }

    func testFailedSelectedPhotoStaysBlockedAcrossSwipesAndSurvivesCancellationAfterRetry() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-batch", "-ui-testing-preview-failure",
            "-ui-testing-preview-preselected", "-ui-testing-delete-cancel"
        ])
        let retry = app.buttons["photo.retryLoad"]
        let select = app.buttons["home.selectPhoto"]
        let clear = app.buttons["home.deleteSelected"]
        let counter = app.staticTexts["home.photoCounter"]
        let carousel = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "1/3")
        XCTAssertEqual(select.value as? String, "선택됨", "A failed preview must retain the saved check")
        XCTAssertEqual(clear.label, "선택한 1장 비우기")
        XCTAssertFalse(clear.isEnabled, "The selected photo must be visible before batch deletion")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.selectedPhoto.")).count, 1)

        scrollToReveal(carousel, in: app)
        for page in [2, 3] {
            carousel.swipeLeft()
            expectation(for: NSPredicate(format: "label == %@", "\(page)/3"), evaluatedWith: counter)
            waitForExpectations(timeout: 5)
            expectation(for: NSPredicate { _, _ in select.exists && select.isEnabled }, evaluatedWith: select)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(select.value as? String, "선택 안 됨")
            XCTAssertEqual(clear.label, "선택한 1장 비우기")
            XCTAssertFalse(clear.isEnabled, "Another photo's successful preview cannot validate the failed selected photo")
        }
        for page in [2, 1] {
            carousel.swipeRight()
            expectation(for: NSPredicate(format: "label == %@", "\(page)/3"), evaluatedWith: counter)
            waitForExpectations(timeout: 5)
        }
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "Returning to the failed photo must still offer retry")
        XCTAssertEqual(select.value as? String, "선택됨")
        XCTAssertFalse(clear.isEnabled)
        scrollToReveal(retry, in: app)
        retry.tap()
        expectation(for: NSPredicate { _, _ in clear.exists && clear.isEnabled }, evaluatedWith: clear)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(clear.label, "선택한 1장 비우기")
        XCTAssertEqual(select.value as? String, "선택됨", "Successful retry must not clear the existing selection")
        let recoveredPreview = XCTAttachment(screenshot: app.screenshot())
        recoveredPreview.name = "Recovered photo keeps selection and enables cleanup"
        recoveredPreview.lifetime = .keepAlways
        add(recoveredPreview)
        scrollToReveal(clear, in: app)
        clear.tap()

        XCTAssertTrue(app.staticTexts["비우기를 취소했어요. 선택한 사진은 그대로예요."].waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "1/3")
        XCTAssertEqual(select.value as? String, "선택됨")
        XCTAssertEqual(clear.label, "선택한 1장 비우기")
        XCTAssertTrue(clear.isEnabled)
        app.buttons["리포트 탭"].tap()
        let deleted = app.staticTexts["report.deletedCount"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 5))
        XCTAssertEqual(deleted.label, "0장", "Cancellation after image recovery must not count a deletion")
        app.buttons["홈 탭"].tap()
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        XCTAssertEqual(select.value as? String, "선택됨")
        XCTAssertEqual(clear.label, "선택한 1장 비우기")
        // This fixture needs an explicit retry for each newly mounted image view.
        // Returning from Report may revalidate the preview; the check must survive it.
    }

    func testHomeDecisionsVisibleWithoutScrollingAtDefaultSize() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: ["-ui-testing-home-batch"])
        let clear = app.buttons["home.deleteSelected"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.finishReviewing"].exists)
        XCTAssertFalse(app.staticTexts["home.retainedPhotoNotice"].exists)
        XCTAssertFalse(app.buttons["home.photoExplanation"].exists)
        let tabs = app.buttons["홈 탭"]
        let photo = app.descendants(matching: .any)["home.photoCarousel"].firstMatch
        XCTAssertTrue(photo.exists)
        let photoFrame = photo.frame
        XCTAssertGreaterThan(photoFrame.width, 0)
        XCTAssertEqual(photoFrame.width, photoFrame.height, accuracy: 1,
                       "Home must scale both photo axes together, including on short phones")
        XCTAssertEqual(photoFrame.midX, app.frame.midX, accuracy: 1)
        XCTAssertEqual(photoFrame.width, app.buttons["home.weeklySummary"].frame.width, accuracy: 1)
        XCTAssertEqual(photoFrame.minX, clear.frame.minX, accuracy: 1)
        XCTAssertEqual(photoFrame.maxX, clear.frame.maxX, accuracy: 1)
        for control in [clear] {
            XCTAssertTrue(control.isHittable, control.identifier)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, control.identifier)
            XCTAssertGreaterThanOrEqual(control.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(control.frame.maxY, tabs.frame.minY + 0.01)
        }
        let select = app.buttons["home.selectPhoto"]
        select.tap()
        XCTAssertTrue(clear.label.contains("1장"))
        XCTAssertEqual(photo.frame.width, photoFrame.width, accuracy: 1)
        XCTAssertEqual(photo.frame.width, photo.frame.height, accuracy: 1)
        XCTAssertTrue(clear.isHittable)
        XCTAssertLessThanOrEqual(clear.frame.maxY, tabs.frame.minY + 0.01)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home square photo and visible cleanup actions"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testCleanupBatchActionsRemainReachableAtLargeText() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-batch", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let select = app.buttons["home.selectPhoto"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        scrollToReveal(select, in: app); select.tap()
        for identifier in ["home.deleteSelected"] {
            let action = app.buttons[identifier]
            scrollToReveal(action, in: app)
            XCTAssertTrue(action.isHittable, identifier)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44, identifier)
            XCTAssertLessThanOrEqual(action.frame.maxY, app.buttons["홈 탭"].frame.minY, identifier)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cleanup selection at accessibility text size"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testCleanupBatchFailurePersistsAndKeepsSelection() {
        let app = launch(route: "-ui-testing-route-main", extraArguments: [
            "-ui-testing-home-batch", "-ui-testing-delete-failure"
        ])
        let select = app.buttons["home.selectPhoto"]
        let clear = app.buttons["home.deleteSelected"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        scrollToReveal(select, in: app); select.tap()
        scrollToReveal(clear, in: app); clear.tap()
        let error = app.staticTexts["home.cleanupFailureTitle"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        scrollToReveal(error, in: app)
        XCTAssertFalse(clear.isEnabled, "Recheck access or photo state before another deletion attempt")
        XCTAssertEqual(select.value as? String, "선택됨")
        XCTAssertTrue(clear.label.contains("1장"))
        XCTAssertTrue(app.staticTexts["home.photoCounter"].label.contains("/3"))
        XCTAssertTrue(app.buttons["home.cleanupPhotoSettings"].exists || app.buttons["home.recheckCleanup"].exists)
        // Verify the recovery message survives longer than the old 3.5s toast.
        let delay = expectation(description: "Persistent recovery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { delay.fulfill() }
        wait(for: [delay], timeout: 5)
        XCTAssertTrue(error.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Persistent cleanup recovery with retained selection"
        shot.lifetime = .keepAlways; add(shot)
    }

    private func declinePhotoPermissionIfPresented(in app: XCUIApplication) {
        let next = app.buttons["photoPermission.request"]
        guard next.waitForExistence(timeout: 3) else { return }
        #if targetEnvironment(simulator)
        scrollToReveal(next, in: app)
        next.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = system.buttons.matching(NSPredicate(format: "label IN %@",
            ["허용 안 함", "허용 안함", "Don't Allow", "Don’t Allow"])).firstMatch
        if deny.waitForExistence(timeout: 5) { deny.tap() }
        XCTAssertTrue(app.buttons["홈 탭"].waitForExistence(timeout: 5))
        #else
        XCTFail("System photo permission changes are simulator-only")
        #endif
    }

    private func continueWithoutAccount(in app: XCUIApplication) {
        let enter = app.buttons["auth.local"]
        XCTAssertTrue(enter.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(enter.label, "로그인 없이 시작하기")
        XCTAssertTrue(app.buttons["auth.apple"].exists || app.staticTexts["auth.configurationStatus"].exists,
                      "Optional Apple login or its unavailable state must leave guest entry accessible")
        XCTAssertFalse(app.buttons["auth.google"].exists)
        XCTAssertFalse(app.buttons["auth.development"].exists)
        scrollToReveal(enter, in: app)
        XCTAssertTrue(enter.isHittable)
        XCTAssertGreaterThanOrEqual(enter.frame.height, 44)
        XCTAssertGreaterThanOrEqual(enter.frame.width, 44)
        XCTAssertGreaterThanOrEqual(enter.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(enter.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(enter.frame.maxY, app.frame.maxY)
        let loginShot = XCTAttachment(screenshot: app.screenshot())
        loginShot.name = "Optional login keeps guest entry reachable"
        loginShot.lifetime = .keepAlways
        add(loginShot)
        enter.tap()
    }

    private func launch(
        route: String,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-reset",
            route
        ] + extraArguments
        app.launch()
        return app
    }
}
