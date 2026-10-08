// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.org).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

// Checks a human-task result against the task's form schema (the memo's `formSchema`). The workflow module checks the
// Ballerina result type instead, which the runtime cannot see; this covers the JSON Schema subset the module emits:
// type, properties, required, enum, items and additionalProperties.

isolated function validateAgainstFormSchema(json value, json schemaText) returns string? {
    if schemaText !is string || schemaText == "" {
        return ();
    }
    json|error schema = schemaText.fromJsonString();
    if schema !is map<json> {
        return ();
    }
    return checkValue(value, schema, "$");
}

isolated function checkValue(json value, map<json> schema, string path) returns string? {
    json enumValues = schema["enum"];
    if enumValues is json[] && enumValues.indexOf(value) is () {
        return string `${path} must be one of ${enumValues.toJsonString()}`;
    }
    json 'type = schema["type"];
    if 'type is string && !hasType(value, 'type) {
        return string `${path} must be ${'type}`;
    }
    if 'type is json[] && !hasAnyType(value, 'type) {
        return string `${path} must be one of the types ${'type.toJsonString()}`;
    }
    if value is map<json> {
        json properties = schema["properties"];
        map<json> props = properties is map<json> ? properties : {};
        json required = schema["required"];
        if required is json[] {
            foreach json name in required {
                if name is string && !value.hasKey(name) {
                    return string `${path}.${name} is required`;
                }
            }
        }
        foreach [string, json] [key, item] in value.entries() {
            json propSchema = props[key];
            if propSchema is map<json> {
                string? nested = checkValue(item, propSchema, path + "." + key);
                if nested is string {
                    return nested;
                }
            } else if schema["additionalProperties"] == false {
                return string `${path}.${key} is not allowed`;
            }
        }
    }
    if value is json[] {
        json items = schema["items"];
        if items is map<json> {
            foreach int i in 0 ..< value.length() {
                string? nested = checkValue(value[i], items, string `${path}[${i}]`);
                if nested is string {
                    return nested;
                }
            }
        }
    }
    return ();
}

isolated function hasType(json value, string 'type) returns boolean {
    match 'type {
        "object" => {
            return value is map<json>;
        }
        "array" => {
            return value is json[];
        }
        "string" => {
            return value is string;
        }
        "integer" => {
            return value is int || (value is decimal && value % 1d == 0d) || (value is float && value % 1.0 == 0.0);
        }
        "number" => {
            return value is int || value is decimal || value is float;
        }
        "boolean" => {
            return value is boolean;
        }
        "null" => {
            return value is ();
        }
    }
    return true;
}

isolated function hasAnyType(json value, json[] types) returns boolean {
    foreach json t in types {
        if t is string && hasType(value, t) {
            return true;
        }
    }
    return false;
}
