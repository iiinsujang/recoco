import Foundation

/// These are review prompts, not assertions that a photo has no value.
/// Missing OCR/face analysis and ambiguous dates fail closed.
struct CurationContextPolicy {
    struct Facts {
        let capturedAt: Date?
        var isScreenshot = false
        var textLines: [String]? = nil
        var confidentTextLines: [String] = []
        var hasFace: Bool? = nil
        var detail: Double? = nil
        var luminanceRange: Double? = nil
        var reviewDate: Date? = nil
    }

    static func evidence(for facts: Facts, now: Date = Date(), calendar: Calendar = .current) -> CurationEvidence? {
        if let reviewDate = facts.reviewDate {
            guard calendar.startOfDay(for: reviewDate) <= calendar.startOfDay(for: now) else { return nil }
            return CurationEvidence(reason: .reviewDateReached, photoDescription: String(localized: "다시 확인하기로 한 사진"),
                                    detail: String(localized: "직접 정한 \(dateText(reviewDate))에 다시 꺼냈어요. 필요하면 계속 보관하세요."),
                                    observedDate: reviewDate)
        }
        guard let captured = facts.capturedAt, captured <= now, let lines = facts.textLines else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: captured),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let text = normalize(lines.joined(separator: " "))
        // A broad safety filter: business/medical/identity records are not temporary-screen guesses.
        let protectedWords = ["영수증", "거래명세", "결제완료", "예약확정", "예약번호", "계약", "진단", "처방",
                              "검사결과", "신분증", "주민등록", "여권", "인증번호", "입장권", "탑승권",
                              "receipt", "invoice", "bookingconfirmed", "passport", "boardingpass",
                              "prescription", "diagnosis", "medicalrecord", "medicalreport",
                              "labresult", "laboratoryresult"]
        guard !protectedWords.contains(where: text.contains) else { return nil }

        let confident = facts.confidentTextLines
        // Never treat a screenshot of a future event/order as past merely because capture is old.
        let allDates = lines.flatMap { explicitDates(in: $0, calendar: calendar) }
        let hasUpcomingDate = allDates.contains { calendar.startOfDay(for: $0) >= calendar.startOfDay(for: now) }
        if facts.isScreenshot, !hasUpcomingDate,
           let expiry = expirationDate(in: confident, calendar: calendar),
           calendar.startOfDay(for: expiry) < calendar.startOfDay(for: now) {
            return CurationEvidence(reason: .expiredScreen, photoDescription: String(localized: "기한이 표시된 스크린샷"),
                                    detail: String(localized: "화면의 행사일·사용 기한을 \(dateText(expiry))로 읽었어요. 날짜가 맞는지, 아직 필요한지 확인해주세요."),
                                    observedDate: expiry)
        }
        guard !hasUpcomingDate else { return nil }
        let reliableText = normalize(confident.joined(separator: " "))
        let temporaryGroups = [
            ["주차", "위치"], ["주차", "층"], ["길찾기", "도착"], ["영업시간", "휴무"],
            ["와이파이", "비밀번호"], ["wifi", "password"], ["parking", "level"]
        ]
        if days >= 7, temporaryGroups.contains(where: { $0.allSatisfy(reliableText.contains) }) {
            return CurationEvidence(reason: .temporaryReference, photoDescription: String(localized: "위치·이용 안내가 담긴 사진"),
                                    detail: String(localized: "안내 문구가 있고 촬영 후 \(days)일이 지났어요. 일시적인 참고 정보일 수 있지만 사용이 끝났는지는 직접 확인해주세요."))
        }
        let shoppingGroups = [
            ["장바구니", "결제하기"], ["상품비교", "가격"], ["배송조회", "배송중"],
            ["배송조회", "배송완료"], ["cart", "checkout"], ["tracking", "delivered"]
        ]
        if facts.isScreenshot, days >= 30, shoppingGroups.contains(where: { $0.allSatisfy(reliableText.contains) }) {
            return CurationEvidence(reason: .shoppingScreen, photoDescription: String(localized: "구매·배송을 참고한 스크린샷"),
                                    detail: String(localized: "구매·배송 관련 문구가 있고 캡처 후 \(days)일이 지났어요. 구매 완료나 보관 필요 여부를 판단한 것은 아니에요."))
        }
        // Low detail alone is weak. Require no detected text/faces, low contrast and elapsed time.
        if !facts.isScreenshot, days >= 7, lines.isEmpty, facts.hasFace == false,
           let detail = facts.detail, detail.isFinite, detail >= 0, detail < 0.001,
           let range = facts.luminanceRange, range.isFinite, range >= 0, range < 0.08 {
            return CurationEvidence(reason: .lowDetail, photoDescription: String(localized: "윤곽과 밝기 차이가 작은 사진"),
                                    detail: String(localized: "윤곽과 밝기 차이가 작고 글자·얼굴이 검출되지 않았어요. 촬영 실수일 수도, 의도한 장면일 수도 있어요."))
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    static func explicitDates(in text: String, calendar: Calendar) -> [Date] {
        // Only complete, explicit years. Never infer this year for a month/day or relative phrase.
        let pattern = #"(?<!\d)(20\d{2})\s*(?:[./-]|년)\s*(\d{1,2})\s*(?:[./-]|월)\s*(\d{1,2})(?:\s*일)?(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        // The OCR pattern accepts explicit Gregorian 20xx dates. A Buddhist or
        // Japanese display calendar must not turn a future expiry into a past date.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let year = Int(ns.substring(with: match.range(at: 1))),
                  let month = Int(ns.substring(with: match.range(at: 2))),
                  let day = Int(ns.substring(with: match.range(at: 3))),
                  let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            let roundtrip = gregorian.dateComponents([.year, .month, .day], from: date)
            guard roundtrip.year == year, roundtrip.month == month, roundtrip.day == day else { return nil }
            return date
        }
    }

    static func expirationDate(in lines: [String], calendar: Calendar) -> Date? {
        let labels = ["유효기간", "사용기한", "사용기간", "행사일", "행사기간", "공연일", "전시기간", "이벤트기간", "validuntil", "expires", "eventdate"]
        var found: [Date] = []
        for (index, line) in lines.enumerated() where labels.contains(where: normalize(line).contains) {
            // Accommodate a label on the line immediately above its date, not arbitrary nearby dates.
            let context = line + " " + (lines.indices.contains(index + 1) ? lines[index + 1] : "")
            if ["제조일", "발급일", "발행일", "생년월일", "구매일", "주문일"].contains(where: normalize(context).contains) { continue }
            let dates = explicitDates(in: context, calendar: calendar)
            guard !dates.isEmpty else { continue }
            // A range must supply its full end date; "2026.01.01 ~ 12.31" is ambiguous.
            let remainder = context.replacingOccurrences(of: #"20\d{2}\s*(?:[./-]|년)\s*\d{1,2}\s*(?:[./-]|월)\s*\d{1,2}(?:\s*일)?"#,
                                                         with: "", options: .regularExpression)
            if (remainder.rangeOfCharacter(from: CharacterSet(charactersIn: "~〜～–—-")) != nil || remainder.contains("부터")), dates.count < 2 { continue }
            found.append(contentsOf: dates)
        }
        return found.max()
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMMd")
        return formatter.string(from: date)
    }
}
