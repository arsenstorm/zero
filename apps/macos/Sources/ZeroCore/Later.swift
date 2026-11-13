import Foundation

/// The words a task starts from to pick up an item saved for later.
public func laterPickUp(_ item: ZerodLink.LaterItem) -> String {
    "Pick up \(item.link): \(item.note)\n\nRead it in full first with `zero later view \(item.id)`, and mark it done with `zero later done \(item.id)` once it is."
}
