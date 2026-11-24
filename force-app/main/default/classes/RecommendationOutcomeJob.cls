/**
 * @description Sends reviewer decisions back to the AI service asynchronously (feedback loop).
 *              Each outcome carries an idempotency key so retries never double-count a decision.
 * @author      Naman G Shetty
 */
public with sharing class RecommendationOutcomeJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer MAX_ATTEMPTS = 3;

    private final List<Outcome> outcomes;
    private final Integer attempt;

    /** @description One reviewer decision. */
    public class Outcome {
        public Id opportunityId;
        public String version;
        public String status;
        public List<String> fields;
        public String idempotencyKey;

        public Outcome(Id opportunityId, String version, String status, List<String> fields) {
            this.opportunityId = opportunityId;
            this.version = version;
            this.status = status;
            this.fields = fields;
            this.idempotencyKey = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',
                Blob.valueOf(opportunityId + '|' + version + '|' + status))).left(32);
        }
    }

    public RecommendationOutcomeJob(List<Outcome> outcomes) {
        this(outcomes, 1);
    }

    private RecommendationOutcomeJob(List<Outcome> outcomes, Integer attempt) {
        this.outcomes = outcomes;
        this.attempt = attempt;
    }

    public void execute(QueueableContext ctx) {
        Boolean ok = false;
        try {
            HttpResponse res = RecommendationClient.send('/recommendations/outcome', new Map<String, Object>{ 'outcomes' => outcomes });
            ok = res.getStatusCode() >= 200 && res.getStatusCode() < 300;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Outcome delivery failed: ' + e.getMessage());
        }
        if (!ok && attempt < MAX_ATTEMPTS && !Test.isRunningTest()) {
            System.enqueueJob(new RecommendationOutcomeJob(outcomes, attempt + 1), attempt * 2); // backoff
        }
    }
}
