import Foundation

extension Timer {
    /// Comme `Timer.scheduledTimer`, mais enregistré en mode `.common`.
    ///
    /// `scheduledTimer` installe le minuteur en mode `.default` : la run loop
    /// bascule en mode `.tracking` pendant qu'on fait défiler une liste, et le
    /// minuteur cesse alors de battre jusqu'à la fin du geste (compte à rebours
    /// figé, sondages en pause…). Le mode `.common` couvre les deux.
    @discardableResult
    static func scheduledCommon(every interval: TimeInterval,
                                repeats: Bool = true,
                                _ block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
