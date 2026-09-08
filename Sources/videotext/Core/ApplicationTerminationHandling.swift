import Foundation

@MainActor
protocol ApplicationTerminationHandling: AnyObject {
    func cancelForApplicationTermination()
    func prepareForApplicationTermination() async
}
