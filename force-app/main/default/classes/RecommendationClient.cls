/**
 * @description HTTP client for the external AI recommendation service.
 * @author      Naman G Shetty
 */
public with sharing class RecommendationClient {

    private static final Integer TIMEOUT_MS = 60000;

    /** @description One AI recommendation for one Opportunity. */
    public class Recommendation {
        public Id opportunityId;
        public String version;
        public String suggestedType;
        public String typeReason;
        public String typeConfidence;
        public String suggestedDescription;
        public String suggestedUsers;
        public String usersConfidence;
    }

    public static List<Recommendation> fetchPending() {
        HttpResponse res = send('/recommendations/query', new Map<String, Object>{ 'status' => 'PENDING', 'pageSize' => 200 });
        if (res.getStatusCode() != 200) {
            throw new CalloutException('Recommendation service returned HTTP ' + res.getStatusCode());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (List<Recommendation>) JSON.deserialize(JSON.serialize(body.get('recommendations')), List<Recommendation>.class);
    }

    /**
     * @description Uses a Named Credential + External Credential so no secret or token handling lives in Apex.
     */
    public static HttpResponse send(String path, Object payload) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AI_Review_Service' + path);
        req.setMethod('POST');
        req.setTimeout(TIMEOUT_MS);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));
        return new Http().send(req);
    }
}
