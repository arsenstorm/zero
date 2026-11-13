import CoreGraphics

/// A menu's pointer intent: moving from one row toward the submenu open beside it crosses other rows, which mustn't
/// switch the submenu on the way (the safe triangle macOS and Amazon's menus use).
public enum MenuAim {
    /// The step from `from` to `to` heads into `menu`: `to` lies in the triangle from `from` to the menu's near edge,
    /// a little past its ends. `leading`: the menu is on the left.
    public static func heading(from: CGPoint, to: CGPoint, menu: CGRect, leading: Bool, slack: CGFloat = 8) -> Bool {
        guard from != to else { return false }
        let x = leading ? menu.maxX : menu.minX
        let top = CGPoint(x: x, y: menu.minY - slack), bottom = CGPoint(x: x, y: menu.maxY + slack)
        func side(_ p: CGPoint, _ q: CGPoint) -> CGFloat { (q.x - p.x) * (to.y - p.y) - (q.y - p.y) * (to.x - p.x) }
        let sides = [side(from, top), side(top, bottom), side(bottom, from)]
        return !(sides.contains { $0 < 0 } && sides.contains { $0 > 0 })
    }
}
