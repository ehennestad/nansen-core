function value = jsonRoundTrip(value)
%jsonRoundTrip A value as it reads back from JSON: what is cached on disk looks like what is computed
    value = jsondecode(jsonencode(value));
end
