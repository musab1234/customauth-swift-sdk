//
//  TorusSwiftDirectSDK class
//  TorusSwiftDirectSDK
//
//  Created by Shubham Rathi on 24/4/2020.
//

import Foundation
import UIKit
import TorusUtils
import PromiseKit
import FetchNodeDetails
import OSLog

// Global variable
var tsSdkLogType = OSLogType.default

@available(iOS 11.0, *)
open class TorusSwiftDirectSDK{
    public var endpoints = Array<String>()
    public var torusNodePubKeys = Array<TorusNodePub>()

    let factory: TDSDKFactoryProtocol
    var torusUtils: AbstractTorusUtils
    let fetchNodeDetails: FetchNodeDetails

    public let aggregateVerifierType: verifierTypes?
    public let aggregateVerifierName: String
    public let subVerifierDetails: [SubVerifierDetails]
    public var authorizeURLHandler: URLOpenerTypes?
    var observer: NSObjectProtocol? // useful for Notifications
    
    public init(aggregateVerifierType: verifierTypes, aggregateVerifierName: String, subVerifierDetails: [SubVerifierDetails], factory: TDSDKFactoryProtocol, network: EthereumNetwork = .MAINNET, loglevel: OSLogType = .debug) {
        
        // factory method
        self.factory = factory
        self.torusUtils = factory.createTorusUtils(level: loglevel, nodePubKeys: [])
        self.fetchNodeDetails = factory.createFetchNodeDetails(network: network)
        
        // verifier details
        self.aggregateVerifierName = aggregateVerifierName
        self.aggregateVerifierType = aggregateVerifierType
        self.subVerifierDetails = subVerifierDetails
    }
    
    public convenience init(aggregateVerifierType: verifierTypes, aggregateVerifierName: String, subVerifierDetails: [SubVerifierDetails]){
        let factory = TDSDKFactory()
        self.init(aggregateVerifierType: aggregateVerifierType, aggregateVerifierName: aggregateVerifierName, subVerifierDetails: subVerifierDetails, factory: factory, network: .MAINNET, loglevel: .debug)
    }
    
    public convenience init(aggregateVerifierType: verifierTypes, aggregateVerifierName: String, subVerifierDetails: [SubVerifierDetails], network: EthereumNetwork){
        let factory = TDSDKFactory()
        self.init(aggregateVerifierType: aggregateVerifierType, aggregateVerifierName: aggregateVerifierName, subVerifierDetails: subVerifierDetails, factory: factory, network: network, loglevel: .debug)
    }
    
    open func getNodeDetailsFromContract() -> Promise<Array<String>>{
        let (tempPromise, seal) = Promise<Array<String>>.pending()
        if(self.endpoints.isEmpty || self.torusNodePubKeys.isEmpty){
            self.fetchNodeDetails.getAllNodeDetails().done{ NodeDetails  in
                // Reinit for the 1st login or if data is missing
                self.torusNodePubKeys = NodeDetails.getTorusNodePub()
                self.endpoints = NodeDetails.getTorusNodeEndpoints()
                self.torusUtils.setTorusNodePubKeys(nodePubKeys: self.torusNodePubKeys)
                // self.torusUtils = self.factory.createTorusUtils(level: self.logger.logLevel, nodePubKeys: self.torusNodePubKeys)
                seal.fulfill(self.endpoints)
            }.catch{error in
                seal.reject(error)
            }
        }else{
            seal.fulfill(self.endpoints)
        }
        
        return tempPromise
    }
    
    open func triggerLogin(controller: UIViewController? = nil, browserType: URLOpenerTypes = .sfsafari, modalPresentationStyle: UIModalPresentationStyle = .fullScreen) -> Promise<[String:Any]>{
        log("triggerLogin called with %@ %@", log: TDSDKLogger.core, type: .info, browserType.rawValue,  modalPresentationStyle.rawValue)
        // Set browser
        self.authorizeURLHandler = browserType
        
        switch self.aggregateVerifierType{
            case .singleLogin:
                return handleSingleLogins(controller: controller, modalPresentationStyle: modalPresentationStyle)
            case .andAggregateVerifier:
                return handleAndAggregateVerifier(controller: controller)
            case .orAggregateVerifier:
                return handleOrAggregateVerifier(controller: controller)
            case .singleIdVerifier:
                return handleSingleIdVerifier(controller: controller, modalPresentationStyle: modalPresentationStyle)
            case .none:
                return Promise(error: TSDSError.methodUnavailable)
        }
    }
    
    open func handleSingleLogins(controller: UIViewController?, modalPresentationStyle: UIModalPresentationStyle = .fullScreen) -> Promise<[String:Any]>{
        let (tempPromise, seal) = Promise<[String:Any]>.pending()
        if let subVerifier = self.subVerifierDetails.first{
            let loginURL = subVerifier.getLoginURL()
            observeCallback{ url in
                let responseParameters = self.parseURL(url: url)
                log("ResponseParams after redirect: %@", log: TDSDKLogger.core, type: .info, responseParameters)

                subVerifier.getUserInfo(responseParameters: responseParameters).then{ newData -> Promise<[String: Any]> in
                    log("getUserInfo newData: %@", log: TDSDKLogger.core, type: .info, newData)
                    var data = newData
                    let verifierId = data["verifierId"] as! String
                    let idToken = data["tokenForKeys"] as! String
                    data.removeValue(forKey: "tokenForKeys")
                    data.removeValue(forKey: "verifierId")
                    
                    return self.getTorusKey(verifier: self.aggregateVerifierName, verifierId: verifierId, idToken: idToken, userData: data)
                }.done{data in
                    seal.fulfill(data)
                }.catch{err in
                    log("handleSingleLogin: err: %s", log: TDSDKLogger.core, type: .error, err.localizedDescription)
                    seal.reject(err)
                }
            }
            openURL(url: loginURL, view: controller, modalPresentationStyle: modalPresentationStyle) // Open in external safari
        }
        return tempPromise
    }
    
    open func handleSingleIdVerifier(controller: UIViewController?, modalPresentationStyle: UIModalPresentationStyle = .fullScreen) -> Promise<[String:Any]>{
        let (tempPromise, seal) = Promise<[String:Any]>.pending()
        if let subVerifier = self.subVerifierDetails.first{
            let loginURL = subVerifier.getLoginURL()
            observeCallback{ url in
                let responseParameters = self.parseURL(url: url)
                log("ResponseParams after redirect: %@", log: TDSDKLogger.core, type: .info, responseParameters)
                subVerifier.getUserInfo(responseParameters: responseParameters).then{ newData -> Promise<[String:Any]> in
                    var data = newData
                    let verifierId = data["verifierId"] as! String
                    let idToken = data["tokenForKeys"] as! String
                    data.removeValue(forKey: "tokenForKeys")
                    data.removeValue(forKey: "verifierId")
                    
                    return self.getAggregateTorusKey(verifier: self.aggregateVerifierName, verifierId: verifierId, idToken: idToken, subVerifierDetails: subVerifier, userData: newData)
                    
                }.done{data in
                    seal.fulfill(data)
                }.catch{err in
                    log("handleSingleIdVerifier err: %s", log: TDSDKLogger.core, type: .error, err.localizedDescription)
                    seal.reject(err)
                }
            }
            openURL(url: loginURL, view: controller, modalPresentationStyle: modalPresentationStyle)
        }
        return tempPromise
    }
    
    func handleAndAggregateVerifier(controller: UIViewController?) -> Promise<[String:Any]>{
        // TODO: implement verifier
        return Promise(error: TSDSError.methodUnavailable)
    }
    
    func handleOrAggregateVerifier(controller: UIViewController?) -> Promise<[String:Any]>{
        // TODO: implement verifier
        return Promise(error: TSDSError.methodUnavailable)
    }
    
    open func getTorusKey(verifier: String, verifierId: String, idToken:String, userData: [String: Any] = [:] ) -> Promise<[String: Any]>{
        let extraParams = ["verifieridentifier": self.aggregateVerifierName, "verifier_id":verifierId] as [String : Any]
        let buffer: Data = try! NSKeyedArchiver.archivedData(withRootObject: extraParams, requiringSecureCoding: false)
        
        let (tempPromise, seal) = Promise<[String: Any]>.pending()
        
        self.getNodeDetailsFromContract().then{ endpoints in
            return self.torusUtils.retrieveShares(endpoints: endpoints, verifierIdentifier: self.aggregateVerifierName, verifierId: verifierId, idToken: idToken, extraParams: buffer)
        }.done{ responseFromRetrieveShares in
            var data = userData
            data["privateKey"] = responseFromRetrieveShares["privateKey"]
            data["publicAddress"] = responseFromRetrieveShares["publicAddress"]
            seal.fulfill(data)
        }.catch{err in
            log("handleSingleLogin: err: %s", log: TDSDKLogger.core, type: .error, err.localizedDescription)
            seal.reject(err)
        }
        
        return tempPromise
    }
    
    open func getAggregateTorusKey(verifier: String, verifierId: String, idToken:String, subVerifierDetails: SubVerifierDetails, userData: [String: Any] = [:]) -> Promise<[String: Any]>{
        let extraParams = ["verifieridentifier": verifier, "verifier_id":verifierId, "sub_verifier_ids":[subVerifierDetails.subVerifierId], "verify_params": [["verifier_id": verifierId, "idtoken": idToken]]] as [String : Any]
        let buffer: Data = try! NSKeyedArchiver.archivedData(withRootObject: extraParams, requiringSecureCoding: false)
        let hashedOnce = idToken.sha3(.keccak256)
        
        let (tempPromise, seal) = Promise<[String: Any]>.pending()
        
        self.getNodeDetailsFromContract().then{ endpoints in
            return self.torusUtils.retrieveShares(endpoints: endpoints, verifierIdentifier: verifier, verifierId: verifierId, idToken: hashedOnce, extraParams: buffer)
        }.done{responseFromRetrieveShares in
            var data = userData
            data["privateKey"] = responseFromRetrieveShares["privateKey"]
            data["publicAddress"] = responseFromRetrieveShares["publicAddress"]
            seal.fulfill(data)
        }.catch{err in
            log("handleSingleIdVerifier err: %@", log: TDSDKLogger.core, type: .error, err.localizedDescription)
            seal.reject(err)
        }
        
        return tempPromise
    }
    
}
