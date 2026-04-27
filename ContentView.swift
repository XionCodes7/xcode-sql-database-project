//
//  ContentView.swift
//  Pumkin's App
//
//  Created by Xion Moten on 9/16/25.
//

import SwiftUI
import SafariServices

// MARK: - App Stores (Cart, Wishlist, Reviews)

final class CartStore: ObservableObject {
    @Published var cartId: String?
    @Published var checkoutUrl: URL?
    @Published var lines: [CartLineDTO] = []
    @Published var isBusy = false
    @Published var error: String?

    func ensureCart() async {
        guard cartId == nil else { return }
        await withBusy {
            do {
                let (id, url) = try await ShopifyClient.cartCreate()
                await MainActor.run {
                    self.cartId = id
                    self.checkoutUrl = url
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func add(variantId: String, qty: Int = 1) async {
        await ensureCart()
        guard let id = cartId else { return }
        await withBusy {
            do {
                let (lines, url) = try await ShopifyClient.cartLinesAdd(cartId: id, variantId: variantId, quantity: qty)
                await MainActor.run {
                    self.lines = lines
                    self.checkoutUrl = url
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func update(lineId: String, qty: Int) async {
        guard let id = cartId else { return }
        await withBusy {
            do {
                let updated = try await ShopifyClient.cartLinesUpdate(cartId: id, updates: [(lineId, qty)])
                await MainActor.run { self.lines = updated }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func remove(lineId: String) async {
        guard let id = cartId else { return }
        await withBusy {
            do {
                let updated = try await ShopifyClient.cartLinesRemove(cartId: id, lineIds: [lineId])
                await MainActor.run { self.lines = updated }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    private func withBusy(_ work: @escaping () async -> Void) async {
        await MainActor.run { isBusy = true; error = nil }
        await work()
        await MainActor.run { isBusy = false }
    }
}

final class WishlistStore: ObservableObject {
    @Published private(set) var ids: Set<String> = []
    private let key = "wishlist.ids"

    init() {
        if let saved = UserDefaults.standard.array(forKey: key) as? [String] {
            ids = Set(saved)
        }
    }
    func toggle(_ productId: String) {
        if ids.contains(productId) { ids.remove(productId) } else { ids.insert(productId) }
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
    func contains(_ productId: String) -> Bool { ids.contains(productId) }
}

struct Review: Identifiable, Codable {
    let id: UUID
    let rating: Int
    let text: String
    let date: Date
}
final class ReviewStore: ObservableObject {
    private func key(_ productId: String) -> String { "reviews.\(productId)" }
    func load(for productId: String) -> [Review] {
        guard let d = UserDefaults.standard.data(forKey: key(productId)),
              let arr = try? JSONDecoder().decode([Review].self, from: d) else { return [] }
        return arr
    }
    func add(for productId: String, rating: Int, text: String) {
        var cur = load(for: productId)
        cur.append(.init(id: UUID(), rating: rating, text: text, date: Date()))
        if let d = try? JSONEncoder().encode(cur) {
            UserDefaults.standard.set(d, forKey: key(productId))
        }
    }
}

// MARK: - Intro

struct IntroScreen: View {
    @State private var switchToMenu = false
    @State private var animateIn = false
    @State private var fadeOut = false

    var body: some View {
        ZStack {
            if switchToMenu {
                MainMenuScreen()
                    .transition(.opacity)
            } else {
                Color.white.ignoresSafeArea()
                Text("Verity")
                    .font(.system(size: 72, weight: .heavy))
                    .foregroundColor(.black)
                    .opacity(fadeOut ? 0 : (animateIn ? 1 : 0))
                    .blur(radius: animateIn ? 0 : 14)
                    .modifier(ShakeEffect(amplitude: 12, shakesPerUnit: 4, animatableData: animateIn ? 1 : 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { animateIn = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                withAnimation(.easeInOut(duration: 0.6)) { fadeOut = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 1.0)) { switchToMenu = true }
            }
        }
    }
}

// MARK: - Shake

struct ShakeEffect: GeometryEffect {
    var amplitude: CGFloat = 10
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = amplitude * sin(animatableData * .pi * shakesPerUnit * 2)
        return ProjectionTransform(CGAffineTransform(translationX: t, y: 0))
    }
}

// MARK: - UI Models

enum Category: String, CaseIterable { case hoodies = "Hoodies", pants = "Pants", tops = "Tops", other = "Other" }

struct HeroCard: Identifiable {
    let id = UUID()
    var imageURL: URL? = nil
    var overlayText: String = ""
}

struct ProductItem: Identifiable, Hashable {
    let id: String                     // use Shopify id to match wishlist/reviews
    var title: String
    var imageURL: URL? = nil
    var price: String
    var buyURL: URL? = nil
    var description: String = ""
    var gallery: [URL] = []
    var variants: [VariantDTO] = []
    var category: Category = .other
}

// MARK: - Main

struct MainMenuScreen: View {
    @StateObject private var cart = CartStore()
    @StateObject private var wishlist = WishlistStore()
    @State private var reviewStore = ReviewStore()

    @State private var searchText = ""
    @State private var selectedTab: MainTab = .home
    @State private var selectedCategory: Category = .hoodies

    // Skeleton data to keep UI visible
    @State private var heroCards: [HeroCard] = Array(repeating: HeroCard(), count: 3)
    @State private var products: [ProductItem] = (1...12).map { _ in ProductItem(id: UUID().uuidString, title: " ", price: " ") }

    // UI
    @State private var badgeText: String = "Rare and Authentic"
    @State private var promoText: String = ""

    // Debug
    @State private var lastError: String? = nil
    @State private var authMsg: String? = nil
    @State private var isAuthTesting = false

    private let productColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var filteredProducts: [ProductItem] {
        switch selectedTab {
        case .categories:
            return products.filter { $0.category == selectedCategory }
        default:
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty { return products }
            return products.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Header
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Verity")
                            .font(.largeTitle.bold())
                            .foregroundColor(.white)
                        HeaderRibbon(text: badgeText)
                        Spacer()
                        // Cart icon with badge
                        NavigationLink {
                            CartScreen().environmentObject(cart)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "cart")
                                    .font(.title2.weight(.semibold))
                                    .foregroundColor(.white)
                                if !cart.lines.isEmpty {
                                    Text("\(cart.lines.reduce(0) {$0 + $1.quantity})")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white)
                                        .padding(4)
                                        .background(Color.red, in: Circle())
                                        .offset(x: 8, y: -6)
                                }
                            }
                        }
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.95))
                        .frame(height: 5 / UIScreen.main.scale)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, -16)

                    SearchBar(text: $searchText) { }
                        .frame(maxWidth: .infinity)

                    if selectedTab == .categories {
                        // Category picker
                        Picker("Category", selection: $selectedCategory) {
                            ForEach(Category.allCases, id: \.self) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.95))
                        .frame(height: 5 / UIScreen.main.scale)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, -16)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(Color.black)

                // Promo
                PromoBannerSolid(text: promoText)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .background(Color.black)

                // Auth tester (optional)
                HStack {
                    Button {
                        Task { await testStorefrontAuth() }
                    } label: {
                        HStack(spacing: 8) { if isAuthTesting { ProgressView() }; Text("Test Auth").font(.callout.weight(.semibold)) }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 4)

                if let m = authMsg {
                    Text(m).font(.footnote).foregroundColor(m.contains("OK") ? .green : .secondary)
                        .padding(.horizontal).padding(.bottom, 6)
                }
                if let msg = lastError {
                    Text(msg).font(.footnote).foregroundColor(.secondary).padding(.vertical, 4)
                }

                // Content
                Group {
                    switch selectedTab {
                    case .home, .categories:
                        ScrollView {
                            VStack(spacing: 12) {
                                // Heros (home only)
                                if selectedTab == .home {
                                    ForEach(Array(heroCards.enumerated()), id: \.offset) { idx, card in
                                        if idx == 1 {
                                            FullWidthSquareCard(imageURL: card.imageURL, text: card.overlayText)
                                        } else {
                                            FullWidthSquareCard(imageURL: card.imageURL, text: card.overlayText)
                                                .padding(.horizontal)
                                        }
                                    }
                                }

                                LazyVGrid(columns: productColumns, spacing: 12) {
                                    ForEach(filteredProducts) { p in
                                        NavigationLink(value: p) {
                                            ProductTile(product: p)
                                                .overlay(alignment: .topTrailing) {
                                                    WishlistHeart(isOn: wishlist.contains(p.id)) {
                                                        wishlist.toggle(p.id)
                                                    }
                                                    .padding(8)
                                                }
                                        }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.bottom, 12)
                            }
                        }

                    case .cart:
                        CartScreen().environmentObject(cart)

                    case .wishlist:
                        WishlistScreen(wishlistProducts: products.filter { wishlist.contains($0.id) })
                            .environmentObject(wishlist)

                    case .account:
                        AccountScreen() // skeleton UI
                    }
                }

                // Bottom nav
                HStack {
                    Spacer()
                    NavButton(icon: "house", label: "Home", isSelected: selectedTab == .home) { selectedTab = .home }
                    Spacer()
                    NavButton(icon: "square.grid.2x2", label: "Categories", isSelected: selectedTab == .categories) { selectedTab = .categories }
                    Spacer()
                    NavButton(icon: "cart", label: "Cart", isSelected: selectedTab == .cart) { selectedTab = .cart }
                    Spacer()
                    NavButton(icon: "heart", label: "Wishlist", isSelected: selectedTab == .wishlist) { selectedTab = .wishlist }
                    Spacer()
                    NavButton(icon: "person", label: "Account", isSelected: selectedTab == .account) { selectedTab = .account }
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(Color.white.shadow(radius: 2))
            }
            .environmentObject(cart)
            .environmentObject(wishlist)
            .transition(.opacity)
            .task {
                await loadProducts()
                await cart.ensureCart()
            }
            .navigationDestination(for: ProductItem.self) { p in
                ProductDetailView(product: p)
                    .environmentObject(cart)
                    .environmentObject(wishlist)
                    .environmentObject(reviewStore)
            }
        }
    }

    // MARK: - Data

    @MainActor
    private func loadProducts() async {
        do {
            let (items, _, _) = try await ShopifyClient.fetchProducts(limit: 50)
            guard !items.isEmpty else {
                lastError = "No products returned. Publish to Headless channel & make them Active."
                return
            }
            let mapped: [ProductItem] = items.map { dto in
                ProductItem(
                    id: dto.id,
                    title: dto.title,
                    imageURL: dto.imageURL,
                    price: dto.priceFormatted,
                    buyURL: dto.buyURL,
                    description: dto.description,
                    gallery: dto.gallery,
                    variants: dto.variants,
                    category: categorize(type: dto.productType, tags: dto.tags, title: dto.title)
                )
            }
            products = mapped
            heroCards = Array(mapped.prefix(3)).map { HeroCard(imageURL: $0.imageURL, overlayText: $0.title) }
            lastError = nil
        } catch {
            lastError = "Load failed: \(error.localizedDescription)"
            print("Shopify load failed:", error)
        }
    }

    private func categorize(type: String, tags: [String], title: String) -> Category {
        let hay = ([type] + tags + [title]).joined(separator: " ").lowercased()
        if hay.contains("hoodie") { return .hoodies }
        if hay.contains("pant") || hay.contains("trouser") || hay.contains("jean") { return .pants }
        if hay.contains("top") || hay.contains("t-shirt") || hay.contains("tee") || hay.contains("shirt") { return .tops }
        return .other
    }

    // MARK: - Auth test

    @MainActor
    private func testStorefrontAuth() async {
        isAuthTesting = true
        defer { isAuthTesting = false }
        do {
            let url = URL(string: "https://\(ShopifyConfig.domain)/api/\(ShopifyConfig.apiVersion)/graphql.json")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(ShopifyConfig.storefrontToken, forHTTPHeaderField: "X-Shopify-Storefront-Access-Token")
            let body = ["query": "{ shop { name } }"]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                authMsg = "OK (200) – Storefront token & domain look good."
            } else if code == 401 || code == 403 {
                authMsg = "HTTP \(code) – Use a Storefront token and your myshopify.com domain."
            } else {
                authMsg = "HTTP \(code) – Unexpected response."
            }
        } catch {
            authMsg = "Auth test error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Detail View (with loader, wishlist, reviews, add to cart)

struct ProductDetailView: View {
    let product: ProductItem
    @EnvironmentObject var cart: CartStore
    @EnvironmentObject var wishlist: WishlistStore
    @EnvironmentObject var reviewStore: ReviewStore

    @State private var showSafari = false
    @State private var showBlink = true
    @State private var selectedVariant: VariantDTO?
    @State private var rating: Int = 5
    @State private var reviewText: String = ""
    @State private var reviews: [Review] = []

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 16) {

                    // Gallery (first image square)
                    if !product.gallery.isEmpty {
                        TabView {
                            ForEach(product.gallery, id: \.self) { u in
                                AsyncOrPlaceholder(url: u)
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .padding(.horizontal)
                            }
                        }
                        .tabViewStyle(.page)
                        .frame(height: UIScreen.main.bounds.width) // square pager
                    } else {
                        AsyncOrPlaceholder(url: product.imageURL)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                    }

                    // Title + Price + Wishlist
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(product.title).font(.title2.bold())
                            Text(product.price).font(.headline).foregroundColor(.secondary)
                        }
                        Spacer()
                        WishlistHeart(isOn: wishlist.contains(product.id)) { wishlist.toggle(product.id) }
                    }
                    .padding(.horizontal)

                    // Variant picker (simple)
                    if !product.variants.isEmpty {
                        let sel = selectedVariant ?? product.variants.first!
                        Picker("Variant", selection: Binding(
                            get: { selectedVariant ?? sel },
                            set: { selectedVariant = $0 }
                        )) {
                            ForEach(product.variants, id: \.self) { v in
                                Text(v.title).tag(v as VariantDTO?)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal)
                    }

                    // Description
                    if !product.description.isEmpty {
                        Text(product.description).font(.body).padding(.horizontal)
                    }

                    // Reviews (local)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reviews").font(.headline)
                        if reviews.isEmpty {
                            Text("Be the first to review this item.").foregroundColor(.secondary)
                        } else {
                            ForEach(reviews) { r in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 2) { ForEach(0..<r.rating, id: \.self) { _ in Image(systemName: "star.fill") } }
                                        .font(.caption).foregroundColor(.yellow)
                                    Text(r.text).font(.subheadline)
                                        .foregroundColor(.primary)
                                }
                                .padding(8)
                                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        // Add review
                        HStack(spacing: 6) {
                            Stepper("Rating: \(rating)", value: $rating, in: 1...5)
                        }
                        TextField("Write a review…", text: $reviewText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        Button("Submit Review") {
                            reviewStore.add(for: product.id, rating: rating, text: reviewText)
                            reviews = reviewStore.load(for: product.id)
                            reviewText = ""
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal)

                    // Add to cart / Buy
                    VStack(spacing: 12) {
                        Button {
                            let variant = selectedVariant ?? product.variants.first
                            if let vid = variant?.id { Task { await cart.add(variantId: vid, qty: 1) } }
                        } label: {
                            HStack { if cart.isBusy { ProgressView() }; Text("Add to Cart") }
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.black).foregroundColor(.white).cornerRadius(12)
                        }
                        .disabled((selectedVariant ?? product.variants.first) == nil)

                        Button {
                            showSafari = true
                        } label: {
                            Text("Checkout")
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.black.opacity(0.85)).foregroundColor(.white).cornerRadius(12)
                        }
                        .disabled(cart.checkoutUrl == nil)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }

            // Micro loader
            if showBlink {
                BlinkingVerityOverlay().transition(.opacity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reviews = reviewStore.load(for: product.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.25)) { showBlink = false }
            }
        }
        .sheet(isPresented: $showSafari) {
            if let url = cart.checkoutUrl {
                SafariView(url: url).ignoresSafeArea()
            }
        }
    }
}

// MARK: - Wishlist Heart

struct WishlistHeart: View {
    var isOn: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "heart.fill" : "heart")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(isOn ? .red : .white)
                .padding(6)
                .background(Color.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Remove from wishlist" : "Add to wishlist")
    }
}

// MARK: - Cart

struct CartScreen: View {
    @EnvironmentObject var cart: CartStore
    @State private var presentCheckout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cart").font(.title.bold()).padding(.horizontal)

            if cart.lines.isEmpty {
                Text("Your cart is empty.")
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                Spacer()
            } else {
                List {
                    ForEach(cart.lines) { line in
                        HStack(spacing: 12) {
                            AsyncOrPlaceholder(url: line.imageURL)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading) {
                                Text(line.productTitle).font(.subheadline.weight(.semibold))
                                Text(line.variantTitle).font(.footnote).foregroundColor(.secondary)
                                Stepper("Qty: \(line.quantity)", value: Binding(
                                    get: { line.quantity },
                                    set: { q in Task { await cart.update(lineId: line.id, qty: q) } }
                                ), in: 1...20)
                                .labelsHidden()
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await cart.remove(lineId: line.id) }
                            } label: { Image(systemName: "trash") }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)

                if let url = cart.checkoutUrl {
                    Button {
                        presentCheckout = true
                    } label: {
                        Text("Checkout")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.black).foregroundColor(.white)
                            .cornerRadius(12)
                            .padding([.horizontal, .bottom])
                    }
                    .sheet(isPresented: $presentCheckout) {
                        SafariView(url: url).ignoresSafeArea()
                    }
                }
            }
        }
    }
}

// MARK: - Wishlist List

struct WishlistScreen: View {
    let wishlistProducts: [ProductItem]
    @EnvironmentObject var wishlist: WishlistStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wishlist").font(.title.bold()).padding(.horizontal)
            if wishlistProducts.isEmpty {
                Text("Your wishlist is empty.").foregroundColor(.secondary).padding(.horizontal)
                Spacer()
            } else {
                List {
                    ForEach(wishlistProducts) { p in
                        HStack {
                            AsyncOrPlaceholder(url: p.imageURL)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading) {
                                Text(p.title).font(.subheadline.weight(.semibold))
                                Text(p.price).font(.footnote).foregroundColor(.secondary)
                            }
                            Spacer()
                            WishlistHeart(isOn: wishlist.contains(p.id)) { wishlist.toggle(p.id) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Account (skeleton)

struct AccountScreen: View {
    var body: some View {
        List {
            Section("Account") {
                Button("Sign In / Sign Up") { /* TODO: wire customer token via Storefront */ }
                Button("Sign Out") { /* TODO */ }
            }
            Section("Orders") {
                Text("Order History")
            }
            Section("Payment Methods") {
                Text("Manage Payment Methods")
            }
            Section("Settings") {
                Text("App Settings")
                Text("Support")
            }
        }
    }
}

// MARK: - Common UI pieces

struct HeaderRibbon: View {
    var text: String
    private let ribbonHeight: CGFloat = 28
    var body: some View {
        let display = text.trimmingCharacters(in: .whitespacesAndNewlines)
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.95), lineWidth: 0.9)
            Text(display.isEmpty ? "hhhhhhhhhhhhhh" : display)
                .font(.footnote.bold())
                .foregroundColor(.white)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, minHeight: ribbonHeight, maxHeight: ribbonHeight)
    }
}

struct PromoBannerSolid: View {
    var text: String
    var body: some View {
        HStack {
            Text(text.isEmpty ? "Everything 50% Off through sunday " : text)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .minimumScaleFactor(0.85)
                .lineLimit(2)
                .padding(.horizontal)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(Color.black)
    }
}

struct FullWidthSquareCard: View {
    var imageURL: URL?
    var text: String
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                AsyncOrPlaceholder(url: imageURL)
                    .frame(width: w, height: w)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(text.isEmpty ? " " : text)
                    .font(.title.bold())
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct ProductTile: View {
    var product: ProductItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncOrPlaceholder(url: product.imageURL)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)      // square box
                .clipShape(RoundedRectangle(cornerRadius: 12)) // crop overflow

            Text(product.title.isEmpty ? " " : product.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.black)
                .lineLimit(1)

            Text(product.price.isEmpty ? " " : product.price)
                .font(.footnote)
                .foregroundColor(.black)
        }
    }
}

struct AsyncOrPlaceholder: View {
    var url: URL?
    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .empty: ZStack { Placeholder(); ProgressView() }
                    case .failure(_): Placeholder()
                    @unknown default: Placeholder()
                    }
                }
            } else {
                Placeholder()
            }
        }
    }
    @ViewBuilder private func Placeholder() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.25))
            Image(systemName: "photo").font(.system(size: 28)).foregroundColor(.gray)
        }
    }
}

struct SearchBar: View {
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search…", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
    }
}

struct NavButton: View {
    var icon: String
    var label: String
    var isSelected: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if isSelected { Circle().fill(Color.gray.opacity(0.2)).frame(width: 36, height: 36) }
                    Image(systemName: icon).font(.system(size: 24, weight: .semibold))
                }
                Text(label).font(.footnote)
            }
            .foregroundColor(.black)
            .padding(.vertical, 6)
            .frame(minWidth: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Micro blinking overlay
struct BlinkingVerityOverlay: View {
    @State private var on = false
    var body: some View {
        Text("VERITY")
            .font(.headline.weight(.heavy))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .opacity(on ? 1 : 0.25)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

// Safari wrapper (in-app checkout sheet)
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - Tabs enum
enum MainTab { case home, categories, cart, wishlist, account }

// MARK: - Previews
#Preview { MainMenuScreen() }
#Preview { IntroScreen() }
