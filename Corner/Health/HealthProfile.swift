import Foundation
#if canImport(HealthKit)
import HealthKit
#endif
import os

/// What Apple Health already knows about the fighter, so the profile screen can
/// offer to fill itself in rather than making them retype it.
///
/// Read-only for now, and deliberately narrow: height, weight, and date of
/// birth are the three things a training app can use and a person shouldn't have
/// to look up. Writing sessions back to Health is a later job — the entitlement
/// and the usage string for it are already in place (see `Config/Corner.entitlements`
/// and the `NSHealthUpdate` key), so it's a code change and not a plumbing one.
///
/// Everything here is best-effort in the same spirit as `AuthController.loadProfile`:
/// Health being unavailable, or the user declining, is a normal state, not an
/// error to surface. The manual fields on the screen are always there; Health is
/// a shortcut, never the only way in.
@MainActor
@Observable
final class HealthProfile {

    /// A single read of the three values, each optional because a person may
    /// have entered none, some, or all of them in Health.
    struct Snapshot {
        var heightCm: Double?
        var weightKg: Double?
        var birthdate: Date?

        var isEmpty: Bool { heightCm == nil && weightKg == nil && birthdate == nil }
    }

    /// Whether this device can talk to Health at all. False on iPad without the
    /// Health app and anywhere HealthKit isn't present — the screen hides the
    /// import affordance rather than offering a button that can only fail.
    var isAvailable: Bool {
        #if canImport(HealthKit)
        HKHealthStore.isHealthDataAvailable()
        #else
        false
        #endif
    }

    private let log = Logger(subsystem: "Giorgi.Corner", category: "health")

    #if canImport(HealthKit)
    private let store = HKHealthStore()

    /// The three types we read. Height and weight are quantities with a history
    /// of samples; date of birth is a characteristic — a single fact with no
    /// timeline — which is why it's read through a different call below.
    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let height = HKObjectType.quantityType(forIdentifier: .height) { types.insert(height) }
        if let weight = HKObjectType.quantityType(forIdentifier: .bodyMass) { types.insert(weight) }
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { types.insert(dob) }
        return types
    }
    #endif

    /// Asks for read access and returns the latest values in one go.
    ///
    /// The authorization sheet only ever appears once per type — iOS remembers
    /// the answer — so calling this on every visit is cheap and correct: it's a
    /// no-op prompt-wise after the first time and just re-reads. It never reports
    /// *whether* access was granted, on purpose: HealthKit refuses to say, so that
    /// an app can't tell "denied" from "no data" and pressure the user over it. A
    /// nil field means the same thing to us either way — nothing to fill in.
    func importSnapshot() async -> Snapshot {
        #if canImport(HealthKit)
        guard isAvailable else { return Snapshot() }

        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            log.info("Health authorization request failed: \(error.localizedDescription, privacy: .public)")
            return Snapshot()
        }

        async let height = latestQuantity(.height, unit: .meterUnit(with: .centi))
        async let weight = latestQuantity(.bodyMass, unit: .gramUnit(with: .kilo))

        return Snapshot(
            heightCm: await height,
            weightKg: await weight,
            birthdate: birthdate()
        )
        #else
        return Snapshot()
        #endif
    }

    #if canImport(HealthKit)
    /// The most recent sample of a quantity, in the unit asked for.
    ///
    /// Sorted newest-first and capped at one: a person's current weight is the
    /// last one they logged, not an average over a year of them.
    private func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }

        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    self.log.info("Health read for \(identifier.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    /// Date of birth from the Health characteristic, if the person set one.
    ///
    /// A synchronous throwing call rather than a query — a characteristic isn't a
    /// sample — and throws specifically when access hasn't been granted, which is
    /// the same nil-means-nothing case everything else here treats quietly.
    private func birthdate() -> Date? {
        do {
            let components = try store.dateOfBirthComponents()
            return Calendar.current.date(from: components)
        } catch {
            return nil
        }
    }
    #endif
}
