import AppKit

final class FinderMenuActionStore {
    private var actions: [Int: URL] = [:]
    private var order: [Int] = []
    private var nextTag = 1

    func register(_ url: URL) -> Int {
        if nextTag == Int.max {
            actions.removeAll()
            order.removeAll()
            nextTag = 1
        }
        let tag = nextTag
        nextTag += 1
        actions[tag] = url
        order.append(tag)
        if order.count > 256 {
            actions.removeValue(forKey: order.removeFirst())
        }
        return tag
    }

    func action(for item: NSMenuItem) -> URL? {
        actions[item.tag]
    }
}
