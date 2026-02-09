// Check if an array contains a given value
// Usage: {{#if (contains autostart_services "marimo")}} ... {{/if}}
let array = params[0];
let value = params[1];

if array.type_of() == "array" {
    for item in array {
        if item == value {
            return true;
        }
    }
}

false
