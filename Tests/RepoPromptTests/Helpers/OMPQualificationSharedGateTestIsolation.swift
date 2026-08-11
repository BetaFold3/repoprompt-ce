#if DEBUG
    actor OMPQualificationSharedGateTestIsolation {
        static let shared = OMPQualificationSharedGateTestIsolation()

        private var occupied = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard occupied else {
                occupied = true
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            guard !waiters.isEmpty else {
                occupied = false
                return
            }
            waiters.removeFirst().resume()
        }
    }
#endif
