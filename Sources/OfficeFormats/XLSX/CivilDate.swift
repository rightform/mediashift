/// A proleptic Gregorian date, computed without `Calendar` so no time zone can shift it.
struct CivilDate {
    var year: Int
    var month: Int
    var day: Int
    var weekday: Int

    init(serial: Int, date1904: Bool) {
        var days: Int
        if date1904 {
            days = serial + Self.days(year: 1904, month: 1, day: 1)
        } else if serial >= 61 {
            days = serial + Self.days(year: 1899, month: 12, day: 30)
        } else if serial == 60 {
            // Excel's famous 1900-02-29, kept from Lotus 1-2-3.
            (year, month, day, weekday) = (1900, 2, 29, 3)
            return
        } else if serial >= 1 {
            days = serial + Self.days(year: 1899, month: 12, day: 31)
        } else {
            // Serial 0 displays as the day before January 1, 1900.
            (year, month, day, weekday) = (1900, 1, 0, 6)
            return
        }

        weekday = ((days + 4) % 7 + 7) % 7
        days += 719_468
        let era = (days >= 0 ? days : days - 146_096) / 146_097
        let dayOfEra = days - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    }

    /// Days since 1970-01-01.
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

extension NumberFormat {
    /// The serial number of a calendar date in the 1900 date system.
    static func serial(year: Int, month: Int, day: Int) -> Int {
        CivilDate.days(year: year, month: month, day: day) - CivilDate.days(year: 1899, month: 12, day: 30)
    }
}
