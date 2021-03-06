//
//  ContentfulSynchronizer.swift
//  ContentfulPersistence
//
//  Created by Boris Bügling on 30/03/16.
//  Copyright © 2016 Contentful GmbH. All rights reserved.
//

import Contentful
import Interstellar

func predicateForIdentifier(identifier: String) -> NSPredicate {
    return NSPredicate(format: "identifier == %@", identifier)
}

/// Provides the ability to sync content from Contentful to a persistence store.
public class ContentfulSynchronizer: SyncSpaceDelegate {
    private let client: Client
    private let matching: [String: AnyObject]
    private let store: PersistenceStore

    private var mappingForEntries = [String: [String: String]]()
    private var mappingForAssets: [String: String]!

    private var typeForAssets: Asset.Type!
    // Dictionary mapping contentTypeId's to Types
    private var typeForEntries = [String: Resource.Type]()
    private var typeForSpaces: Space.Type!

    // Dictionary mapping Entry identifier's to a dictionary with fieldName to related entry id's.
    private var relationshipsToResolve = [String: [String: Any]]()

    var syncToken: String? {
        return fetchSpace().syncToken
    }

    /**
     Instantiate a new ContentfulSynchronizer.

     - parameter client:           The API client to use for synchronization
     - parameter persistenceStore: The persistence store to use for storage
     - parameter matching:         An optional query for syncing specific content, see <https://www.contentful.com/developers/docs/references/content-delivery-api/#/reference/synchronization/initial-synchronisation-of-entries-of-a-specific-content-type>

     - returns: An initialised instance of ContentfulSynchronizer
     */
    public init(client: Client, persistenceStore: PersistenceStore, matching: [String: AnyObject] = [String: AnyObject]()) {
        self.client = client
        self.matching = matching
        self.store = persistenceStore
    }

    /**
     Specify the type that Entries of a specific Content Type should be mapped to.

     The given type needs to implement the `Resource` protocol. Optionally, a field mapping can be
     provided which specifies the mapping between Contentful fields and properties of the target type.

     By default, this mapping will be automatically derived through matching fields and properties which
     share the same name. If you are using the Contentful Xcode plugin to generate your data model, the
     assumptions of the default mapping should usually suffice.

     - parameter contentTypeId:   ID of the Content Type which is being mapped
     - parameter type:            The type Entries should be mapped to (needs to implement the `Resource` protocol)
     - parameter propertyMapping: Optional mapping between Contentful fields and object properties
     */
    public func map(contentTypeId contentTypeId: String, to type: Resource.Type, propertyMapping: [String:String]? = nil) {
        mappingForEntries[contentTypeId] = propertyMapping
        typeForEntries[contentTypeId] = type
    }

    /**
     Specify the type that Assets should be mapped to.

     The given type needs to implement the `Asset` protocol. Optionally, a field mapping can be
     provided which specifies the mapping between Contentful fields and properties of the target type.

     By default, this mapping will be automatically derived through matching fields and properties which
     share the same name. For this, also the sub-fields of the `file` and `file.details.image` fields
     are being taken into consideration, e.g. if your type has a `width` property, the image width
     provided by Contentful would be mapped to it.

     - parameter type:            The type Assets should be mapped to (needs to implement the `Asset` protocol)
     - parameter propertyMapping: Optional mapping between Contentful fields and object properties
     */
    public func mapAssets(to type: Asset.Type, propertyMapping: [String:String]? = nil) {
        mappingForAssets = propertyMapping
        typeForAssets = type
    }

    /**
     Specify the type that Spaces are mapped to.

     The given type needs to implement the `Space` protocol.

     - parameter type: The type Spaces should be mapped to (needs to implement the `Space` protocol)
     */
    public func mapSpaces(to type: Space.Type) {
        typeForSpaces = type
    }

    /**
     Perform a synchronization. This will fetch new content from Contentful and save it to the
     persistent store.

     - parameter completion: A completion handler which is called after completing the sync process.
     */
    public func sync(completion: (Bool) -> ()) {
        assert(typeForAssets != nil, "Define a type for Assets using mapAssets(to:)")
        assert(typeForEntries.first?.1 != nil, "Define a type for Entries using map(contentTypeId:to:)")
        assert(typeForSpaces != nil, "Define a type for Spaces using mapSpaces(to:)")

        var initial: Bool?

        let syncCompletion: (Result<SyncSpace>) -> () = { result in

            switch result {
            case .Success(let syncSpace):

                // Fetch the current space
                var space = self.fetchSpace()
                space.syncToken = syncSpace.syncToken

                // Delegate callback will createEntries when necessary.
                if let initial = initial where initial == true {

                    for asset in syncSpace.assets {
                        self.createAsset(asset)
                    }
                    for entry in syncSpace.entries {
                        self.createEntry(entry)
                    }
                }

                self.resolveRelationships()
                _ = try? self.store.save()
                completion(true)

            case .Error(let error):
                NSLog("Error: \(error)")
                completion(false)
            }
        }

        if let syncToken = syncToken {
            initial = false
            let syncSpace = SyncSpace(client: client, syncToken: syncToken, delegate: self)
            syncSpace.sync(matching, completion: syncCompletion)
        } else {
            initial = true
            client.initialSync(completion: syncCompletion)
        }

        relationshipsToResolve.removeAll()
    }

    // MARK: - Helpers

    // Attempts to fetch the object from the the persistent store, if it exists,
    private func create(identifier: String, fields: [String: Any], type: Resource.Type, mapping: [String: String]) {
        assert(mapping.count > 0, "Empty mapping for \(type)")

        let fetched: [Resource]? = try? store.fetchAll(type, predicate: predicateForIdentifier(identifier))
        let persisted: Resource

        if let fetched = fetched?.first {
            persisted = fetched
        } else {
            persisted = try! store.create(type)
            persisted.identifier = identifier
        }

        if let persisted = persisted as? NSObject {
            map(fields, to: persisted, mapping: mapping)
        }
    }

    private func deriveMapping(fields: [String], type: Resource.Type, prefix: String = "") -> [String: String] {
        var mapping = [String: String]()
        let properties = (try! store.propertiesFor(type: type)).filter { propertyName in
            fields.contains(propertyName)
        }
        properties.forEach { mapping["\(prefix)\($0)"] = $0 }
        return mapping
    }

    private func fetchSpace() -> Space {
        // FIXME: the predicate could be a bit safer and actually use the space identifier.
        let result: [Space]? = try? self.store.fetchAll(self.typeForSpaces, predicate: NSPredicate(value: true))

        guard let space = result?.first else {
            return try! self.store.create(self.typeForSpaces)
        }

        assert(result?.count == 1)
        return space
    }

    private func map(fields: [String: Any], to: NSObject, mapping: [String: String]) {
        for (mapKey, mapValue) in mapping {

            var fieldValue = valueFor(fields, keyPath: mapKey)

            if let string = fieldValue as? String where string.hasPrefix("//") && mapValue == "url" {
                fieldValue = "https:\(string)"
            }

            // handle symbol arrays
            if let array = fieldValue as? NSArray {
                fieldValue = NSKeyedArchiver.archivedDataWithRootObject(array)
            }

            to.setValue(fieldValue as? NSObject, forKeyPath: mapValue)
        }
    }

    private func resolveRelationships() {
        let entryTypes = typeForEntries.map { contentTypeId, type in
            return type
        }
        let cache = DataCache(persistenceStore: store, assetType: typeForAssets, entryTypes: entryTypes)

        for (entryId, field) in relationshipsToResolve {
            if let entry = cache.entryForIdentifier(entryId) as? NSObject {

                for (fieldName, relatedEntryId) in field {
                    if let identifier = relatedEntryId as? String {
                        entry.setValue(cache.itemForIdentifier(identifier), forKey: fieldName)
                    }

                    if let identifiers = relatedEntryId as? [String] {
                        let targets = identifiers.flatMap { id in
                            return cache.itemForIdentifier(id)
                        }
                        entry.setValue(NSOrderedSet(array: targets), forKey: fieldName)
                    }
                }
            }
        }
    }

    // MARK: - SyncSpaceDelegate

    /**
     This function is public as a side-effect of implementing `SyncSpaceDelegate`.

     - parameter asset: The newly created Asset
     */
    public func createAsset(asset: Contentful.Asset) {
        if mappingForAssets == nil {
            mappingForAssets = deriveMapping(Array(asset.fields.keys), type: typeForAssets)

            ["file", "file.details.image"].forEach {
                if let fileFields = valueFor(asset.fields, keyPath: $0) as? [String: AnyObject] {
                    mappingForAssets! += deriveMapping(Array(fileFields.keys), type: typeForAssets, prefix: "\($0).")
                }
            }
        }

        create(asset.identifier, fields: asset.fields, type: typeForAssets, mapping: mappingForAssets)
    }

    private func getIdentifier(target: Any) -> String? {
        if let target = target as? Contentful.Asset {
            return target.identifier
        }

        if let target = target as? Entry {
            return target.identifier
        }

        // For links that have not yet been resolved.
        if let jsonObject = target as? [String:AnyObject],
            let sys = jsonObject["sys"] as? [String:AnyObject],
            let identifier = sys["id"] as? String {
            return identifier
        }

        return nil
    }

    /**
     This function is public as a side-effect of implementing `SyncSpaceDelegate`.

     - parameter entry: The newly created Entry
     */
    public func createEntry(entry: Entry) {

        let contentTypeId = ((entry.sys["contentType"] as? [String: AnyObject])?["sys"] as? [String: AnyObject])?["id"] as? String

        if let contentTypeId = contentTypeId, type = typeForEntries[contentTypeId] {
            var mapping = mappingForEntries[contentTypeId]
            if mapping == nil {
                mapping = deriveMapping(Array(entry.fields.keys), type: type)
            }

            create(entry.identifier, fields: entry.fields, type: type, mapping: mapping!)

            // ContentTypeId to either a single entry id or an array of entry id's to be linked.
            var relationships = [String: Any]()

            // Get fieldNames which are links/relationships/references to other types.
            if let relationshipNames = try? store.relationshipsFor(type: type) {

                for relationshipName in relationshipNames {

                    if let target = entry.fields[relationshipName] {
                        if let targets = target as? [Any] {
                            // One-to-many.
                            relationships[relationshipName] = targets.flatMap { self.getIdentifier($0) }
                        } else if let targets = target as? [AnyObject] {
                            // Workaround for when cast to [Any] fails; generally when the array still contains
                            // Dictionary respresentation of link.
                            relationships[relationshipName] = targets.flatMap { self.getIdentifier($0) }
                        } else {
                            // One-to-one.
                            relationships[relationshipName] = getIdentifier(target)
                        }
                    }
                }
            }

            relationshipsToResolve[entry.identifier] = relationships
        }
    }

    /**
     This function is public as a side-effect of implementing `SyncSpaceDelegate`.

     - parameter assetId: The ID of the deleted Asset
     */
    public func deleteAsset(assetId: String) {
        _ = try? store.delete(typeForAssets, predicate: predicateForIdentifier(assetId))
    }

    /**
     This function is public as a side-effect of implementing `SyncSpaceDelegate`.

     - parameter entryId: The ID of the deleted Entry
     */
    public func deleteEntry(entryId: String) {
        let predicate = predicateForIdentifier(entryId)

        typeForEntries.forEach {
            _ = try? self.store.delete($0.1, predicate: predicate)
        }
    }
}
