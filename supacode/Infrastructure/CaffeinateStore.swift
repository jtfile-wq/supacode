import Foundation
import Observation

/// App-global keep-awake toggle behind the toolbar caffeinate pill. Holds a
/// ProcessInfo activity that blocks idle system sleep while still letting the
/// display sleep, matching `caffeinate -i`. Session-only by design: the
/// assertion dies with the process, so a relaunch always starts with sleep
/// allowed and a forgotten toggle can't drain a battery across days.
@MainActor
@Observable
final class CaffeinateStore {
  static let shared = CaffeinateStore()

  private(set) var isOn = false

  // Injectable so tests can observe begin/end pairing without taking a real
  // power assertion.
  @ObservationIgnored private let beginActivity: () -> NSObjectProtocol
  @ObservationIgnored private let endActivity: (NSObjectProtocol) -> Void
  @ObservationIgnored private var activity: NSObjectProtocol?

  init(
    beginActivity: @escaping () -> NSObjectProtocol = {
      ProcessInfo.processInfo.beginActivity(
        options: .idleSystemSleepDisabled,
        reason: "Keep Mac awake while agents run"
      )
    },
    endActivity: @escaping (NSObjectProtocol) -> Void = {
      ProcessInfo.processInfo.endActivity($0)
    }
  ) {
    self.beginActivity = beginActivity
    self.endActivity = endActivity
  }

  func toggle() {
    if let activity {
      endActivity(activity)
      self.activity = nil
      isOn = false
    } else {
      activity = beginActivity()
      isOn = true
    }
  }
}
