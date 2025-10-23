;; Waste Collection Coordinator Contract
;; Records collection events with weight verification, validates plastic quality,
;; distributes reward tokens, and tracks environmental impact

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-invalid-weight (err u102))
(define-constant err-invalid-quality (err u103))
(define-constant err-insufficient-balance (err u104))
(define-constant err-already-exists (err u105))
(define-constant err-invalid-collector (err u106))
(define-constant err-reward-pool-empty (err u107))
(define-constant err-invalid-location (err u108))

;; Reward rates per kg of plastic (in micro-tokens)
(define-constant reward-rate-high-quality u100)
(define-constant reward-rate-medium-quality u75)
(define-constant reward-rate-low-quality u50)

;; Quality thresholds (0-100 scale)
(define-constant high-quality-threshold u80)
(define-constant medium-quality-threshold u50)
(define-constant min-quality-threshold u30)

;; Data Variables
(define-data-var total-plastic-collected uint u0)
(define-data-var total-collections uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var reward-pool-balance uint u1000000000) ;; Initial reward pool
(define-data-var collection-counter uint u0)
(define-data-var active-collectors uint u0)

;; Data Maps
(define-map collections
    { collection-id: uint }
    {
        collector: principal,
        weight: uint,
        quality-score: uint,
        timestamp: uint,
        location: (string-ascii 100),
        verified: bool,
        reward-amount: uint
    }
)

(define-map collectors
    { collector: principal }
    {
        total-weight: uint,
        total-collections: uint,
        total-rewards: uint,
        last-collection: uint,
        reputation-score: uint,
        active: bool
    }
)

(define-map collector-balances
    { collector: principal }
    { balance: uint }
)

(define-map quality-validations
    { collection-id: uint }
    {
        validator: principal,
        validation-time: uint,
        approved: bool,
        notes: (string-ascii 200)
    }
)

(define-map daily-stats
    { date: uint }
    {
        collections: uint,
        total-weight: uint,
        rewards-distributed: uint
    }
)

;; Private Functions
(define-private (calculate-reward (weight uint) (quality-score uint))
    (let
        (
            (rate (if (>= quality-score high-quality-threshold)
                    reward-rate-high-quality
                    (if (>= quality-score medium-quality-threshold)
                        reward-rate-medium-quality
                        reward-rate-low-quality)))
        )
        (* weight rate)
    )
)

(define-private (update-collector-reputation (collector principal) (quality-score uint))
    (let
        (
            (collector-data (default-to
                { total-weight: u0, total-collections: u0, total-rewards: u0, 
                  last-collection: u0, reputation-score: u50, active: true }
                (map-get? collectors { collector: collector })))
            (current-rep (get reputation-score collector-data))
            (new-rep (if (> quality-score high-quality-threshold)
                        (+ current-rep u1)
                        (if (< quality-score min-quality-threshold)
                            (if (> current-rep u0) (- current-rep u1) u0)
                            current-rep)))
        )
        new-rep
    )
)

(define-private (is-valid-quality (quality-score uint))
    (and (>= quality-score min-quality-threshold) (<= quality-score u100))
)

(define-private (get-current-day)
    (/ stacks-block-height u144) ;; Approximate blocks per day
)

;; Public Functions

;; Record a new collection event
(define-public (record-collection (weight uint) (quality-score uint) (location (string-ascii 100)))
    (let
        (
            (collector tx-sender)
            (collection-id (+ (var-get collection-counter) u1))
            (reward (calculate-reward weight quality-score))
            (current-day (get-current-day))
        )
        ;; Validate inputs
        (asserts! (> weight u0) err-invalid-weight)
        (asserts! (is-valid-quality quality-score) err-invalid-quality)
        (asserts! (> (len location) u0) err-invalid-location)
        (asserts! (<= reward (var-get reward-pool-balance)) err-reward-pool-empty)
        
        ;; Create collection record
        (map-set collections
            { collection-id: collection-id }
            {
                collector: collector,
                weight: weight,
                quality-score: quality-score,
                timestamp: stacks-block-height,
                location: location,
                verified: false,
                reward-amount: reward
            }
        )
        
        ;; Update or create collector profile
        (match (map-get? collectors { collector: collector })
            collector-data
            (map-set collectors
                { collector: collector }
                {
                    total-weight: (+ (get total-weight collector-data) weight),
                    total-collections: (+ (get total-collections collector-data) u1),
                    total-rewards: (+ (get total-rewards collector-data) reward),
                    last-collection: stacks-block-height,
                    reputation-score: (update-collector-reputation collector quality-score),
                    active: true
                }
            )
            ;; First time collector
            (begin
                (map-set collectors
                    { collector: collector }
                    {
                        total-weight: weight,
                        total-collections: u1,
                        total-rewards: reward,
                        last-collection: stacks-block-height,
                        reputation-score: u50,
                        active: true
                    }
                )
                (var-set active-collectors (+ (var-get active-collectors) u1))
            )
        )
        
        ;; Update collector balance
        (match (map-get? collector-balances { collector: collector })
            balance-data
            (map-set collector-balances
                { collector: collector }
                { balance: (+ (get balance balance-data) reward) }
            )
            (map-set collector-balances
                { collector: collector }
                { balance: reward }
            )
        )
        
        ;; Update daily statistics
        (match (map-get? daily-stats { date: current-day })
            stats
            (map-set daily-stats
                { date: current-day }
                {
                    collections: (+ (get collections stats) u1),
                    total-weight: (+ (get total-weight stats) weight),
                    rewards-distributed: (+ (get rewards-distributed stats) reward)
                }
            )
            (map-set daily-stats
                { date: current-day }
                { collections: u1, total-weight: weight, rewards-distributed: reward }
            )
        )
        
        ;; Update global statistics
        (var-set collection-counter collection-id)
        (var-set total-plastic-collected (+ (var-get total-plastic-collected) weight))
        (var-set total-collections (+ (var-get total-collections) u1))
        (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) reward))
        (var-set reward-pool-balance (- (var-get reward-pool-balance) reward))
        
        (ok collection-id)
    )
)

;; Validate quality of a collection
(define-public (validate-quality (collection-id uint) (approved bool) (notes (string-ascii 200)))
    (let
        (
            (collection (unwrap! (map-get? collections { collection-id: collection-id }) err-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        
        ;; Record validation
        (map-set quality-validations
            { collection-id: collection-id }
            {
                validator: tx-sender,
                validation-time: stacks-block-height,
                approved: approved,
                notes: notes
            }
        )
        
        ;; Update collection verified status
        (map-set collections
            { collection-id: collection-id }
            (merge collection { verified: approved })
        )
        
        (ok true)
    )
)

;; Withdraw rewards
(define-public (withdraw-rewards (amount uint))
    (let
        (
            (collector tx-sender)
            (balance-data (unwrap! (map-get? collector-balances { collector: collector }) err-not-found))
            (current-balance (get balance balance-data))
        )
        (asserts! (>= current-balance amount) err-insufficient-balance)
        
        ;; Update balance
        (map-set collector-balances
            { collector: collector }
            { balance: (- current-balance amount) }
        )
        
        (ok amount)
    )
)

;; Replenish reward pool (owner only)
(define-public (replenish-pool (amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set reward-pool-balance (+ (var-get reward-pool-balance) amount))
        (ok true)
    )
)

;; Read-Only Functions

;; Get collection details
(define-read-only (get-collection (collection-id uint))
    (ok (map-get? collections { collection-id: collection-id }))
)

;; Get collector stats
(define-read-only (get-collector-stats (collector principal))
    (ok (map-get? collectors { collector: collector }))
)

;; Get collector balance
(define-read-only (get-collector-balance (collector principal))
    (ok (map-get? collector-balances { collector: collector }))
)

;; Get total plastic collected
(define-read-only (get-total-plastic-collected)
    (ok (var-get total-plastic-collected))
)

;; Get total collections count
(define-read-only (get-total-collections)
    (ok (var-get total-collections))
)

;; Get total rewards distributed
(define-read-only (get-total-rewards-distributed)
    (ok (var-get total-rewards-distributed))
)

;; Get reward pool balance
(define-read-only (get-reward-pool-balance)
    (ok (var-get reward-pool-balance))
)

;; Get active collectors count
(define-read-only (get-active-collectors)
    (ok (var-get active-collectors))
)

;; Get daily statistics
(define-read-only (get-daily-stats (date uint))
    (ok (map-get? daily-stats { date: date }))
)

;; Get quality validation
(define-read-only (get-quality-validation (collection-id uint))
    (ok (map-get? quality-validations { collection-id: collection-id }))
)

;; Verify if collection exists and is verified
(define-read-only (verify-collection (collection-id uint))
    (match (map-get? collections { collection-id: collection-id })
        collection (ok (get verified collection))
        err-not-found
    )
)

;; Calculate potential reward
(define-read-only (calculate-potential-reward (weight uint) (quality-score uint))
    (ok (calculate-reward weight quality-score))
)

;; Get environmental impact metrics
(define-read-only (get-impact-metrics)
    (ok {
        total-plastic-collected: (var-get total-plastic-collected),
        total-collections: (var-get total-collections),
        active-collectors: (var-get active-collectors),
        total-rewards-distributed: (var-get total-rewards-distributed)
    })
)

;; title: waste-collection-coordinator
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

