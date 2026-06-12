import UIKit

extension UIApplication {
    static var safeAreaTop: CGFloat {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 47
    }
    static var safeAreaBottom: CGFloat {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34
    }
}
