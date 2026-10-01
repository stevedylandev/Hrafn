import SwiftUI

extension View {
    /// Keeps `value` in step with a database observation for as long as the
    /// view is on screen, restarting it when `id` changes.
    func observing<Value: Sendable, ID: Equatable>(
        _ stream: @escaping () -> AsyncThrowingStream<Value, any Error>,
        id: ID,
        into value: Binding<Value>,
        isLoaded: Binding<Bool>? = nil
    ) -> some View {
        task(id: id) {
            isLoaded?.wrappedValue = false
            do {
                for try await next in stream() {
                    value.wrappedValue = next
                    isLoaded?.wrappedValue = true
                }
            } catch {
                // Cancellation when the view goes away; nothing to report.
                if !Task.isCancelled { isLoaded?.wrappedValue = true }
            }
        }
    }
}
