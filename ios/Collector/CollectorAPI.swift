import Foundation
import Security

enum CollectorKeychain {
    static let service="com.eachpathhealth.collector.session"
    static func store(_ value:String?) throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"operator"]
        SecItemDelete(query as CFDictionary)
        if let value {
            var insert=query; insert[kSecValueData as String]=Data(value.utf8)
            insert[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary,nil)==errSecSuccess else { throw CollectorError.message("Unable to store session in Keychain") }
        }
    }
    static func read()->String? {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"operator",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var value:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&value)==errSecSuccess,let data=value as? Data else {return nil}
        return String(data:data,encoding:.utf8)
    }
}
final class CollectorAPI {
    var base:URL?
    var token=CollectorKeychain.read()
    private let session:URLSession
    init() {
        let config=URLSessionConfiguration.ephemeral
        config.urlCache=nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage=nil; config.timeoutIntervalForRequest=60; config.timeoutIntervalForResource=90
        session=URLSession(configuration:config)
    }
    func configure(_ endpoint:String) throws {
        guard let url=URL(string:endpoint),url.scheme=="https",url.host != nil,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil else {throw CollectorError.message("Enter the backend HTTPS address")}
        if let old=UserDefaults.standard.string(forKey:"collectorEndpoint"),old != endpoint {token=nil;try CollectorKeychain.store(nil)}
        base=url
        // Only nonsecret configuration is persisted. Session/specimen/review state is reloaded from Neon.
        UserDefaults.standard.set(endpoint,forKey:"collectorEndpoint")
    }
    func request(_ path:String,method:String="GET",json:Any?=nil,bytes:Data?=nil,metadata:Data?=nil,id:String?=nil) async throws ->Data {
        guard let base else {throw CollectorError.message("Configure the backend first")}
        guard let url=URL(string:base.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+path) else {throw CollectorError.message("Invalid endpoint")}
        var req=URLRequest(url:url);req.httpMethod=method;req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        if let token {req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
        if let json {req.httpBody=try JSONSerialization.data(withJSONObject:json);req.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        if let bytes {
            req.httpBody=bytes;req.setValue("image/jpeg",forHTTPHeaderField:"Content-Type")
            req.setValue(metadata?.base64EncodedString(),forHTTPHeaderField:"X-Capture");req.setValue(id,forHTTPHeaderField:"Idempotency-Key")
        }
        let (data,response)=try await session.data(for:req)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
            let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let code=(response as? HTTPURLResponse)?.statusCode ?? 0
            throw CollectorError.http(code,object?["error"] as? String ?? "Backend unavailable")
        }
        return data
    }
    func get<T:Decodable>(_ path:String,as type:T.Type) async throws ->T {try JSONDecoder().decode(type,from:await request(path))}
    func login(username:String,password:String) async throws {
        let data=try await request("/v1/login",method:"POST",json:["username":username,"password":password])
        let object=try JSONSerialization.jsonObject(with:data) as? [String:String]
        guard let value=object?["token"] else {throw CollectorError.message("Invalid login response")}
        try CollectorKeychain.store(value);token=value
    }
}
