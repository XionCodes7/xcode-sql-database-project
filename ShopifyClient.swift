
import Foundation

// MARK: - Config
enum ShopifyConfig {
    static let domain          = "domain"
    static let storefrontToken = "YOUR_API_KEY_HERE"
    static let apiVersion      = "version"
}

// MARK: - DTOs

struct VariantDTO: Identifiable, Hashable {
    let id: String
    let title: String
}

struct ShopifyProductDTO: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let productType: String
    let tags: [String]
    let imageURL: URL?
    let gallery: [URL]
    let priceFormatted: String
    let buyURL: URL?
    let variants: [VariantDTO]
}

struct CartLineDTO: Identifiable, Hashable {
    let id: String
    let quantity: Int
    let variantId: String
    let variantTitle: String
    let productTitle: String
    let imageURL: URL?
}

// MARK: - Client

enum ShopifyClient {

    // -------- PRODUCTS --------

    static func fetchProducts(limit: Int = 24, after cursor: String? = nil)
    async throws -> ([ShopifyProductDTO], hasNext: Bool, endCursor: String?) {

        let url = URL(string: "https://\(ShopifyConfig.domain)/api/\(ShopifyConfig.apiVersion)/graphql.json")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ShopifyConfig.storefrontToken, forHTTPHeaderField: "X-Shopify-Storefront-Access-Token")

        let query = """
        query Products($first:Int!, $after:String) {
          products(first: $first, after: $after, sortKey: UPDATED_AT, reverse: true) {
            pageInfo { hasNextPage endCursor }
            edges {
              cursor
              node {
                id
                title
                description
                productType
                tags
                handle
                onlineStoreUrl
                featuredImage { url }
                images(first: 5) { edges { node { url } } }
                priceRange { minVariantPrice { amount currencyCode } }
                variants(first: 10) {
                  edges { node { id title } }
                }
              }
            }
          }
        }
        """

        let body: [String: Any] = [
            "query": query,
            "variables": ["first": limit, "after": cursor as Any]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Shopify", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Bad response \(code). Body: \(text)"])
        }

        let decoded = try JSONDecoder().decode(ProductsResponse.self, from: data)
        let items: [ShopifyProductDTO] = decoded.data.products.edges.map { edge in
            let n = edge.node
            let price = n.priceRange.minVariantPrice
            let featured = URL(string: n.featuredImage?.url ?? "")
            let gallery = n.images.edges.compactMap { URL(string: $0.node.url) }
            let variants = n.variants.edges.map { VariantDTO(id: $0.node.id, title: $0.node.title) }

            // Prefer Shopify-built online store URL; fallback to myshopify.com/products/{handle}
            let primary = URL(string: n.onlineStoreUrl ?? "")
            let fallback = URL(string: "https://\(ShopifyConfig.domain)/products/\(n.handle)")
            let buyURL = primary ?? fallback

            return ShopifyProductDTO(
                id: n.id,
                title: n.title,
                description: n.description,
                productType: n.productType,
                tags: n.tags,
                imageURL: featured,
                gallery: gallery,
                priceFormatted: formatPrice(amount: price.amount, code: price.currencyCode),
                buyURL: buyURL,
                variants: variants
            )
        }

        return (items, decoded.data.products.pageInfo.hasNextPage, decoded.data.products.pageInfo.endCursor)
    }

    // -------- CART --------

    static func cartCreate() async throws -> (cartId: String, checkoutUrl: URL) {
        let mutation = """
        mutation CartCreate($input: CartInput!) {
          cartCreate(input: $input) {
            cart { id checkoutUrl }
            userErrors { message }
          }
        }
        """
        let vars: [String: Any] = ["input": [:]]

        let root = try await postGraphQL(query: mutation, variables: vars)
        let obj = try JSONDecoder().decode(CartCreateResponse.self, from: root)
        guard let cart = obj.data.cartCreate.cart,
              let url = URL(string: cart.checkoutUrl) else {
            let msg = obj.data.cartCreate.userErrors.first?.message ?? "Unknown error creating cart"
            throw NSError(domain: "Shopify", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return (cart.id, url)
    }

    static func cartLinesAdd(cartId: String, variantId: String, quantity: Int) async throws -> (lines: [CartLineDTO], checkoutUrl: URL) {
        let mutation = """
        mutation CartLinesAdd($cartId: ID!, $lines: [CartLineInput!]!) {
          cartLinesAdd(cartId: $cartId, lines: $lines) {
            cart {
              checkoutUrl
              lines(first: 50) {
                edges {
                  node {
                    id
                    quantity
                    merchandise {
                      ... on ProductVariant {
                        id
                        title
                        product {
                          title
                          featuredImage { url }
                        }
                      }
                    }
                  }
                }
              }
            }
            userErrors { message }
          }
        }
        """
        let line: [String: Any] = ["quantity": quantity, "merchandiseId": variantId]
        let vars: [String: Any] = ["cartId": cartId, "lines": [line]]

        let data = try await postGraphQL(query: mutation, variables: vars)
        let obj = try JSONDecoder().decode(CartLinesAddResponse.self, from: data)
        guard let cart = obj.data.cartLinesAdd.cart,
              let url = URL(string: cart.checkoutUrl) else {
            let msg = obj.data.cartLinesAdd.userErrors.first?.message ?? "Unknown error adding lines"
            throw NSError(domain: "Shopify", code: -3, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return (mapCartLines(cart.lines.edges), url)
    }

    static func cartLinesUpdate(cartId: String, updates: [(lineId: String, quantity: Int)]) async throws -> [CartLineDTO] {
        let mutation = """
        mutation CartLinesUpdate($cartId: ID!, $lines: [CartLineUpdateInput!]!) {
          cartLinesUpdate(cartId: $cartId, lines: $lines) {
            cart {
              lines(first: 50) {
                edges {
                  node {
                    id
                    quantity
                    merchandise {
                      ... on ProductVariant {
                        id
                        title
                        product {
                          title
                          featuredImage { url }
                        }
                      }
                    }
                  }
                }
              }
            }
            userErrors { message }
          }
        }
        """
        let mapped: [[String: Any]] = updates.map { ["id": $0.lineId, "quantity": $0.quantity] }
        let vars: [String: Any] = ["cartId": cartId, "lines": mapped]

        let data = try await postGraphQL(query: mutation, variables: vars)
        let obj = try JSONDecoder().decode(CartLinesUpdateResponse.self, from: data)
        guard let lines = obj.data.cartLinesUpdate.cart?.lines.edges else {
            let msg = obj.data.cartLinesUpdate.userErrors.first?.message ?? "Update failed"
            throw NSError(domain: "Shopify", code: -4, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return mapCartLines(lines)
    }

    static func cartLinesRemove(cartId: String, lineIds: [String]) async throws -> [CartLineDTO] {
        let mutation = """
        mutation CartLinesRemove($cartId: ID!, $lineIds: [ID!]!) {
          cartLinesRemove(cartId: $cartId, lineIds: $lineIds) {
            cart {
              lines(first: 50) {
                edges {
                  node {
                    id
                    quantity
                    merchandise {
                      ... on ProductVariant {
                        id
                        title
                        product {
                          title
                          featuredImage { url }
                        }
                      }
                    }
                  }
                }
              }
            }
            userErrors { message }
          }
        }
        """
        let vars: [String: Any] = ["cartId": cartId, "lineIds": lineIds]

        let data = try await postGraphQL(query: mutation, variables: vars)
        let obj = try JSONDecoder().decode(CartLinesRemoveResponse.self, from: data)
        guard let lines = obj.data.cartLinesRemove.cart?.lines.edges else {
            let msg = obj.data.cartLinesRemove.userErrors.first?.message ?? "Remove failed"
            throw NSError(domain: "Shopify", code: -5, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return mapCartLines(lines)
    }

    // MARK: - Private helpers

    private static func postGraphQL(query: String, variables: [String: Any]) async throws -> Data {
        let url = URL(string: "https://\(ShopifyConfig.domain)/api/\(ShopifyConfig.apiVersion)/graphql.json")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ShopifyConfig.storefrontToken, forHTTPHeaderField: "X-Shopify-Storefront-Access-Token")
        let body: [String: Any] = ["query": query, "variables": variables]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Shopify", code: code, userInfo: [NSLocalizedDescriptionKey: "Bad response \(code). Body: \(text)"])
        }
        return data
    }

    private static func formatPrice(amount: String, code: String) -> String {
        guard let val = Double(amount) else { return "\(amount) \(code)" }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = code
        return nf.string(from: NSNumber(value: val)) ?? "\(amount) \(code)"
    }

    private static func mapCartLines(_ edges: [CartLinesEdge]) -> [CartLineDTO] {
        edges.map { e in
            let m = e.node.merchandise.variant
            return CartLineDTO(
                id: e.node.id,
                quantity: e.node.quantity,
                variantId: m.id,
                variantTitle: m.title,
                productTitle: m.product.title,
                imageURL: URL(string: m.product.featuredImage?.url ?? "")
            )
        }
    }

    // MARK: - Decodables (Products)

    private struct ProductsResponse: Decodable {
        let data: DataNode
        struct DataNode: Decodable { let products: Products }
        struct Products: Decodable {
            let pageInfo: PageInfo
            let edges: [Edge]
        }
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        struct Edge: Decodable { let cursor: String; let node: Node }
        struct Node: Decodable {
            let id: String
            let title: String
            let description: String
            let productType: String
            let tags: [String]
            let handle: String
            let onlineStoreUrl: String?
            let featuredImage: FeaturedImage?
            let images: Images
            let priceRange: PriceRange
            let variants: Variants

            struct FeaturedImage: Decodable { let url: String }
            struct Images: Decodable {
                let edges: [ImageEdge]
                struct ImageEdge: Decodable { let node: ImageNode }
                struct ImageNode: Decodable { let url: String }
            }
            struct PriceRange: Decodable { let minVariantPrice: VariantPrice }
            struct VariantPrice: Decodable { let amount: String; let currencyCode: String }
            struct Variants: Decodable {
                let edges: [VariantEdge]
                struct VariantEdge: Decodable { let node: VariantNode }
                struct VariantNode: Decodable { let id: String; let title: String }
            }
        }
    }

    // MARK: - Decodables (Cart)

    private struct CartCreateResponse: Decodable {
        let data: DataNode
        struct DataNode: Decodable {
            let cartCreate: CartCreate
            struct CartCreate: Decodable {
                let cart: Cart?
                let userErrors: [UserError]
            }
        }
    }

    private struct CartLinesAddResponse: Decodable {
        let data: DataNode
        struct DataNode: Decodable {
            let cartLinesAdd: Payload
            struct Payload: Decodable {
                let cart: Cart?
                let userErrors: [UserError]
            }
        }
    }

    private struct CartLinesUpdateResponse: Decodable {
        let data: DataNode
        struct DataNode: Decodable {
            let cartLinesUpdate: Payload
            struct Payload: Decodable {
                let cart: Cart?
                let userErrors: [UserError]
            }
        }
    }

    private struct CartLinesRemoveResponse: Decodable {
        let data: DataNode
        struct DataNode: Decodable {
            let cartLinesRemove: Payload
            struct Payload: Decodable {
                let cart: Cart?
                let userErrors: [UserError]
            }
        }
    }

    private struct Cart: Decodable {
        let id: String
        let checkoutUrl: String
        let lines: Lines
        struct Lines: Decodable {
            let edges: [CartLinesEdge]
        }
    }

    fileprivate struct CartLinesEdge: Decodable {
        let node: Node
        struct Node: Decodable {
            let id: String
            let quantity: Int
            let merchandise: Merchandise
            struct Merchandise: Decodable {
                let variant: Variant
                enum CodingKeys: String, CodingKey { case variant = "on_ProductVariant" }
                init(from decoder: Decoder) throws {
                    // Decode inline fragment ... on ProductVariant
                    let c = try decoder.singleValueContainer()
                    self.variant = try c.decode(Variant.self)
                }
                struct Variant: Decodable {
                    let id: String
                    let title: String
                    let product: Product
                    struct Product: Decodable {
                        let title: String
                        let featuredImage: FeaturedImage?
                        struct FeaturedImage: Decodable { let url: String }
                    }
                }
            }
        }
    }

    private struct UserError: Decodable { let message: String }
}

