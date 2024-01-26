import ballerinax/redis;
import ballerina/persist;

# The client used by the generated persist clients to abstract and 
# execute Redis queries that are required to perform CRUD operations.
public isolated client class RedisClient {

    private final redis:Client dbClient;

    private final string & readonly entityName;
    private final string & readonly collectionName;
    private final map<FieldMetadata> & readonly fieldMetadata;
    private final string[] & readonly keyFields;

    # Initializes the `RedisClient`.
    #
    # + dbClient - The `redis:Client`, which is used to execute Redis queries
    # + metadata - Metadata of the entity
    # + return - A `persist:Error` if the client creation fails
    public isolated function init(redis:Client dbClient, RedisMetadata & readonly metadata) returns persist:Error? {
        self.entityName = metadata.entityName;
        self.collectionName = metadata.collectionName;
        self.fieldMetadata = metadata.fieldMetadata;
        self.keyFields = metadata.keyFields;
        self.dbClient = dbClient;
    }

    # Performs a batch `HGET` operation to get entity instances as a stream
    # 
    # + rowType - The type description of the entity to be retrieved
    # + key - Key for the record
    # + fields - The fields to be retrieved
    # + include - The associations to be retrieved
    # + typeDescriptions - The type descriptions of the relations to be retrieved
    # + return - An `record{||} & readonly` containing the requested record
    public isolated function runReadByKeyQuery(typedesc<record {}> rowType, anydata key, string[] fields = [], string[] include = [], typedesc<record {}>[] typeDescriptions = []) returns record{}|error {
        
        if key is string[]{
            string recordKey = self.collectionName;
            // assume the key fields are in the same order as when inserting a new record
            foreach string keyField in key{
                recordKey += ":"+keyField;
            }

            do {
                // return check self.querySimpleFieldsByKey(recordKey, fields).cloneWithType(rowType);
                record{} 'object = check self.querySimpleFieldsByKey(recordKey, fields);
                check self.getManyRelations('object, fields, include);
                self.removeUnwantedFields('object, fields);
                return check 'object.cloneWithType(rowType);
            } on fail error e {
                return <persist:Error>e;
            }
        }else{
            return error("Invalid data type for key");
        }
    }

    # Performs a batch `HGET` operation to get entity instances as a stream
    # 
    # + rowType - The type description of the entity to be retrieved
    # + fields - The fields to be retrieved
    # + include - The associations to be retrieved
    # + return - A stream of `record{||} & readonly` containing the requested records
    public isolated function runReadQuery(typedesc<record {}> rowType, string[] fields = [], string[] include = []) returns stream<record{}|error>|error {
        // Get all the keys
        string[]keys = check self.dbClient->keys(self.collectionName+":*");

        // Get data one by one using the key
        record{}[] result = [];
        foreach string key in keys {
            do{
                // handling simple fields
                record{} 'object = check self.querySimpleFieldsByKey(key, fields);
                check self.getManyRelations('object, fields, include);
                self.removeUnwantedFields('object, fields);

                result.push(check 'object.cloneWithType(rowType));
                // handling relation fields later 
            } on fail error e {
                return <persist:Error>e;
            }
            
        }

        return stream from record{} rec in result select rec;
    }

    # Performs a batch `HMSET` operation to insert entity instances into a collection.
    #
    # + insertRecords - The entity records to be inserted into the collection
    # + return - A `string` containing the information of the query execution
    # or a `persist:Error` if the operation fails
    public isolated function runBatchInsertQuery(record {}[] insertRecords) returns string|persist:Error|error {

        string|error result;

        // for each record do HMSET
        foreach var insertRecord in insertRecords {

            // Create the key
            string key = "";
            foreach string keyField in self.keyFields {
                key = key + ":" + insertRecord[keyField].toString(); // get the key field value by member access method.
            }

            // check for duplicate keys withing the collection
            int isKeyExists = check self.dbClient->exists([self.collectionName+key]);
            if isKeyExists != 0 {
                return persist:getAlreadyExistsError(self.collectionName, key);
            }

            // inserting the object
            result = self.dbClient->hMSet(self.collectionName+key, insertRecord);
            if result is error{
                return error persist:Error(result.message());
            }
        }

        // Decide how to log queries
        // logQuery("RQL insert query: ", insertQueries);
        if result is string {
            return result;
        }
        return error persist:Error(result.message());
    }

    # Performs redis `DEL` operation to delete an entity record from the database.
    #
    # + keyFieldValues - The ordered keys used to delete an entity record
    # + return - `()` if the operation is performed successfully or a `persist:Error` if the operation fails
    public isolated function runDeleteQuery(any [] keyFieldValues) returns persist:Error?|error {
        // Validate fields
        if (keyFieldValues.length() != self.keyFields.length()){
            return error("Missing keyfields");
        }

        // Generate the key
        string recordKey = self.collectionName;
        foreach any value in keyFieldValues{
            recordKey += ":"+value.toString();
        }

        // Delete the record
        _ = check self.dbClient->del([recordKey]);
    }

    # Performs redis `HSET` operation to delete an entity record from the database.
    #
    # + keyFieldValues - The ordered keys used to update an entity record
    # + updateRecord - The new record to be updated
    # + return - An Error if the new record is missing a keyfield
    public isolated function runUpdateQuery(any [] keyFieldValues, record {} updateRecord) returns error? {
        // Validate fields
        if (keyFieldValues.length() != self.keyFields.length()){
            return error("Missing keyfields");
        }

        // Generate the key
        string key = self.collectionName;
        foreach any keyFieldValue in keyFieldValues{
            key += ":"+keyFieldValue.toString();
        }

        // decide on how to update only the given fields that is not equals to ()
        foreach [string, FieldMetadata & readonly] metaDataEntry in self.fieldMetadata.entries() {
            FieldMetadata & readonly fieldMetadataValue = metaDataEntry[1];

            // if the field is a simple field
            if(fieldMetadataValue is SimpleFieldMetadata){
                if (updateRecord.hasKey(fieldMetadataValue.fieldName) && updateRecord[fieldMetadataValue.fieldName] != ()){
                    // updating the object
                    _ = check self.dbClient->hSet(key, fieldMetadataValue.fieldName, updateRecord[fieldMetadataValue.fieldName].toString());
                }
            }
            // if the field is a relation field
            else{

            }
        }
    }

    public isolated function getKeyFields() returns string[] {
        return self.keyFields;
    }

    public isolated function querySimpleFieldsByKey(string key, string[] fields) returns record {}|persist:Error{
        // hadling the simple fields
        string[] simpleFields = self.getSimpleFields(fields);
        if simpleFields == [] { // then add all the fields by default
            foreach [string, FieldMetadata & readonly] metaDataEntry in self.fieldMetadata.entries() {
                FieldMetadata & readonly fieldMetadataValue = metaDataEntry[1];

                // if the field is a simple field
                if(fieldMetadataValue is SimpleFieldMetadata){
                    simpleFields.push(fieldMetadataValue.fieldName);
                }
            }
        }

        do {
	
	        map<any> value = check self.dbClient->hMGet(key, simpleFields);
            record{} valueToRecord = {};
            foreach string fieldKey in value.keys() {
                // convert the data type from 'any' to required type
                valueToRecord[fieldKey] = check self.dataConverter(<FieldMetadata & readonly>self.fieldMetadata[fieldKey], value[fieldKey]);
            }
            return valueToRecord;
        } on fail var e {
        	return <persist:Error>e;
        }
    }

    public isolated function getSimpleFields(string[] fields) returns string[] {
        string[] simpleFields = from string 'field in fields
            where !'field.includes("[].")
            select 'field;
        return simpleFields;
    }

    public isolated function getManyRelations(record {} 'object,string[] fields, string[] include) returns persist:Error? {
        foreach int i in 0 ..< include.length() {
            string entity = include[i];
            string[] relationFields = from string 'field in fields
                where 'field.startsWith(entity + "[].")
                select 'field.substring(entity.length() + 3, 'field.length());

            if relationFields.length() is 0 {
                continue;
            }

            string[]keys = check self.dbClient->keys(entity.substring(0,1).toUpperAscii()+entity.substring(1)+":*");

            // Get data one by one using the key
            record{}[] associatedRecords = [];
            foreach string key in keys {
                // handling simple fields
                record{} valueToRecord = check self.querySimpleFieldsByKey(key, relationFields);

                foreach string fieldKey in valueToRecord.keys() {
                    // convert the data type from 'any' to required type
                    valueToRecord[fieldKey] = check self.dataConverter(<FieldMetadata & readonly>self.fieldMetadata[entity+"[]."+fieldKey], valueToRecord[fieldKey]);
                }

                // check whether the record is associated with the current object
                boolean isAssociated = true;
                foreach string keyField in self.keyFields{
                    boolean isSimilar = valueToRecord[entity+keyField.substring(0,1).toUpperAscii()+keyField.substring(1)] == 'object[keyField];
                    if !isSimilar {
                        isAssociated = false;
                    }
                }

                if isAssociated {
                    associatedRecords.push(valueToRecord);
                }
                
            }

            'object[entity] = associatedRecords;
        } on fail var e {
        	return <persist:Error>e;
        }
    }

    private isolated function removeUnwantedFields(record {} 'object, string[] fields) {
        string[] keyFields = self.keyFields;

        foreach string keyField in keyFields {
            if fields.indexOf(keyField) is () {
                _ = 'object.remove(keyField);
            }
        }
    }

    public isolated function dataConverter(FieldMetadata & readonly fieldMetaData, any value) returns ()|boolean|string|float|error|int {

        // Return nil if value is nil
        if(value is ()){
            return ();
        }
    
        if((fieldMetaData is SimpleFieldMetadata && fieldMetaData[FIELD_DATA_TYPE] == INT)
        || (fieldMetaData is EntityFieldMetadata && fieldMetaData[RELATION][REF_FIELD_DATA_TYPE] == INT)){
            return check int:fromString(<string>value);
        }else if((fieldMetaData is SimpleFieldMetadata  && (fieldMetaData[FIELD_DATA_TYPE] == STRING))
        || (fieldMetaData is EntityFieldMetadata && fieldMetaData[RELATION][REF_FIELD_DATA_TYPE] == STRING)){
            return <string>value;
        }else if((fieldMetaData is SimpleFieldMetadata  && fieldMetaData[FIELD_DATA_TYPE] == FLOAT)
        || (fieldMetaData is EntityFieldMetadata && fieldMetaData[RELATION][REF_FIELD_DATA_TYPE] == FLOAT)){
            return check float:fromString(<string>value);
        }else if((fieldMetaData is SimpleFieldMetadata  && fieldMetaData[FIELD_DATA_TYPE] == BOOLEAN)
        || (fieldMetaData is EntityFieldMetadata && fieldMetaData[RELATION][REF_FIELD_DATA_TYPE] == BOOLEAN)){
            return check boolean:fromString(<string>value);
        }else{
            return error("Unsupported Data Format");
        }
    }


}