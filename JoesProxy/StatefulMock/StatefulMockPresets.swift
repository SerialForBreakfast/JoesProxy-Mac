//
//  StatefulMockPresets.swift
//  JoesProxy
//
//  Built-in state-machine presets for E-Commerce, Auth, Streaming, and Subscriptions.
//

import Foundation

enum StatefulMockPresets {

    static let allPresets: [StatefulMockPreset] = [
        ecommerceCartPreset,
        authLifecyclePreset,
        streamingPlayerPreset,
        subscriptionTiersPreset
    ]

    // MARK: - E-Commerce Cart Preset

    static let ecommerceCartPreset = StatefulMockPreset(
        id: "ecommerce_cart",
        title: "E-Commerce Cart & Checkout Flow",
        summary: "Models shopping cart additions, coupon code application, and checkout state transitions.",
        defaultHost: "api.store.example.com",
        backendFactory: { host in
            StatefulVirtualBackend(
                name: "E-Commerce Cart Backend",
                originHost: host,
                description: "Stateful shopping cart with checkout state machine and product collection.",
                initialState: "EmptyCart",
                possibleStates: ["EmptyCart", "ItemAdded", "PromoApplied", "CheckedOut", "PaymentDeclined"],
                supportedCollections: ["products", "cart_items"],
                transitionRules: [
                    StatefulMockTransitionRule(
                        fromState: "EmptyCart",
                        toState: "ItemAdded",
                        method: "POST",
                        pathPattern: "/cart/items",
                        responseStatusCode: 201,
                        responseBodyTemplate: "{\n  \"status\": \"item_added\",\n  \"cart\": {\n    \"itemCount\": 1,\n    \"subtotal\": 49.99,\n    \"currency\": \"USD\"\n  }\n}"
                    ),
                    StatefulMockTransitionRule(
                        fromState: "ItemAdded",
                        toState: "PromoApplied",
                        method: "POST",
                        pathPattern: "/cart/promo",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"status\": \"promo_applied\",\n  \"discount\": 10.00,\n  \"newTotal\": 39.99\n}"
                    ),
                    StatefulMockTransitionRule(
                        fromState: "PromoApplied",
                        toState: "CheckedOut",
                        method: "POST",
                        pathPattern: "/cart/checkout",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"status\": \"order_confirmed\",\n  \"orderId\": \"{{uuid}}\",\n  \"amountCharged\": 39.99,\n  \"createdAt\": \"{{now}}\"\n}"
                    ),
                    StatefulMockTransitionRule(
                        fromState: "ItemAdded",
                        toState: "CheckedOut",
                        method: "POST",
                        pathPattern: "/cart/checkout",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"status\": \"order_confirmed\",\n  \"orderId\": \"{{uuid}}\",\n  \"amountCharged\": 49.99,\n  \"createdAt\": \"{{now}}\"\n}"
                    )
                ]
            )
        },
        initialEntities: [
            StatefulMockEntity(
                id: "prod_001",
                collection: "products",
                fields: ["title": "Wireless Noise-Cancelling Headphones", "price": "199.99", "inStock": "true"]
            ),
            StatefulMockEntity(
                id: "prod_002",
                collection: "products",
                fields: ["title": "Ergonomic Mechanical Keyboard", "price": "129.99", "inStock": "true"]
            )
        ]
    )

    // MARK: - Auth Lifecycle Preset

    static let authLifecyclePreset = StatefulMockPreset(
        id: "auth_lifecycle",
        title: "Authentication & Token Refresh Lifecycle",
        summary: "Models user login, MFA challenges, session expiry (401), and token refresh.",
        defaultHost: "auth.example.com",
        backendFactory: { host in
            StatefulVirtualBackend(
                name: "Auth Lifecycle Backend",
                originHost: host,
                description: "Stateful authentication flow with token refresh and expiry simulation.",
                initialState: "LoggedOut",
                possibleStates: ["LoggedOut", "MFAPending", "Authenticated", "TokenExpired"],
                supportedCollections: ["users"],
                transitionRules: [
                    StatefulMockTransitionRule(
                        fromState: "LoggedOut",
                        toState: "Authenticated",
                        method: "POST",
                        pathPattern: "/auth/login",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"accessToken\": \"mock_jwt_{{uuid}}\",\n  \"expiresIn\": 3600,\n  \"user\": {\n    \"id\": \"usr_100\",\n    \"name\": \"Alice Dev\"\n  }\n}"
                    ),
                    StatefulMockTransitionRule(
                        fromState: "TokenExpired",
                        toState: "Authenticated",
                        method: "POST",
                        pathPattern: "/auth/refresh",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"accessToken\": \"refreshed_jwt_{{uuid}}\",\n  \"expiresIn\": 3600\n}"
                    ),
                    StatefulMockTransitionRule(
                        fromState: "Authenticated",
                        toState: "LoggedOut",
                        method: "POST",
                        pathPattern: "/auth/logout",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"status\": \"logged_out\"\n}"
                    )
                ]
            )
        },
        initialEntities: [
            StatefulMockEntity(
                id: "usr_100",
                collection: "users",
                fields: ["email": "alice@example.com", "role": "admin", "status": "active"]
            )
        ]
    )

    // MARK: - Streaming Player Preset

    static let streamingPlayerPreset = StatefulMockPreset(
        id: "streaming_player",
        title: "Video Streaming & Midroll Ad Break",
        summary: "Models playback session initialization, midroll ad injection, and stream completion.",
        defaultHost: "stream.example.com",
        backendFactory: { host in
            StatefulVirtualBackend(
                name: "Streaming Player Backend",
                originHost: host,
                description: "Simulates playback sessions and dynamic ad break transitions.",
                initialState: "Idle",
                possibleStates: ["Idle", "PlayingContent", "MidrollAdBreak", "ContentResumed", "StreamEnded"],
                supportedCollections: ["tracks"],
                transitionRules: [
                    StatefulMockTransitionRule(
                        fromState: "Idle",
                        toState: "PlayingContent",
                        method: "POST",
                        pathPattern: "/playback/start",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"sessionID\": \"{{uuid}}\",\n  \"streamURL\": \"https://stream.example.com/live/master.m3u8\",\n  \"duration\": 1800\n}"
                    ),
                    StatefulMockTransitionRule(
                        fromState: "PlayingContent",
                        toState: "MidrollAdBreak",
                        method: "POST",
                        pathPattern: "/playback/trigger-ad",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"adPodID\": \"ad_pod_{{uuid}}\",\n  \"duration\": 30,\n  \"skippable\": false\n}"
                    ),
                    StatefulMockTransitionRule(
                        fromState: "MidrollAdBreak",
                        toState: "ContentResumed",
                        method: "POST",
                        pathPattern: "/playback/resume",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"status\": \"resumed\",\n  \"resumeOffsetSeconds\": 600\n}"
                    )
                ]
            )
        },
        initialEntities: []
    )

    // MARK: - Subscription Tiers Preset

    static let subscriptionTiersPreset = StatefulMockPreset(
        id: "subscription_tiers",
        title: "Subscription Tiers & Entitlements",
        summary: "Models Free vs Pro plan states, in-app purchase upgrades, and payment past due.",
        defaultHost: "billing.example.com",
        backendFactory: { host in
            StatefulVirtualBackend(
                name: "Subscription & Billing Backend",
                originHost: host,
                description: "Simulates subscription tier upgrades and past-due billing states.",
                initialState: "FreeTier",
                possibleStates: ["FreeTier", "UpgradePending", "ProActive", "PastDue"],
                supportedCollections: ["plans"],
                transitionRules: [
                    StatefulMockTransitionRule(
                        fromState: "FreeTier",
                        toState: "ProActive",
                        method: "POST",
                        pathPattern: "/subscription/upgrade",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"tier\": \"PRO\",\n  \"status\": \"active\",\n  \"renewsAt\": \"{{now}}\"\n}"
                    ),
                    StatefulMockTransitionRule(
                        fromState: "ProActive",
                        toState: "PastDue",
                        method: "POST",
                        pathPattern: "/subscription/billing-fail",
                        responseStatusCode: 200,
                        responseBodyTemplate: "{\n  \"tier\": \"PRO\",\n  \"status\": \"past_due\",\n  \"gracePeriodDaysRemaining\": 3\n}"
                    )
                ]
            )
        },
        initialEntities: [
            StatefulMockEntity(id: "plan_free", collection: "plans", fields: ["name": "Starter Free", "price": "0.00"]),
            StatefulMockEntity(id: "plan_pro", collection: "plans", fields: ["name": "Pro Unlimited", "price": "19.99"])
        ]
    )
}
