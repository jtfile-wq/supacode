import Foundation
import Testing

@testable import supacode

@MainActor
struct CaffeinateStoreTests {
  @Test func togglePairsBeginAndEndExactlyOnce() {
    var begins = 0
    var ends = 0
    let token = NSObject()
    let store = CaffeinateStore(
      beginActivity: {
        begins += 1
        return token
      },
      endActivity: { ended in
        ends += 1
        #expect(ended === token)
      }
    )

    #expect(!store.isOn)

    store.toggle()
    #expect(store.isOn)
    #expect(begins == 1)
    #expect(ends == 0)

    store.toggle()
    #expect(!store.isOn)
    #expect(begins == 1)
    #expect(ends == 1)

    store.toggle()
    #expect(store.isOn)
    #expect(begins == 2)
    #expect(ends == 1)
  }
}
