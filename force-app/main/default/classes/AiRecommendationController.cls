/**
 * @description Human-in-the-loop review of AI recommendations for Opportunities.
 *              - Recommendations live in an external AI service (no staging objects in Salesforce).
 *              - Salesforce enforces record access: IDs returned by the service are re-filtered WITH USER_MODE.
 *              - Protected fields (already populated by a human) are never offered or overwritten.
 *              - Decisions are saved in Salesforce, then sent back asynchronously to close the AI feedback loop.
 * @author      Naman G Shetty
 */
public with sharing class AiRecommendationController {

    @TestVisible private static final Integer MAX_APPLY = 10;

    /** @description A reviewable row shown in the LWC. */
    public class Row {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public String opportunityName;
        @AuraEnabled public String accountName;
        @AuraEnabled public String version;
        @AuraEnabled public String suggestedType;
        @AuraEnabled public String typeReason;
        @AuraEnabled public String typeConfidence;
        @AuraEnabled public String suggestedDescription;
        @AuraEnabled public String suggestedUsers;
        @AuraEnabled public Boolean typeEditable;
        @AuraEnabled public Boolean descriptionEditable;
        @AuraEnabled public Boolean usersEditable;
    }

    /** @description A reviewer decision for one Opportunity. */
    public class Decision {
        @AuraEnabled public Id opportunityId { get; set; }
        @AuraEnabled public String version { get; set; }
        @AuraEnabled public String action { get; set; } // ACCEPT | REJECT
        @AuraEnabled public String type { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String users { get; set; }
    }

    /**
     * @description Returns rows the running user may review. Uses Platform Cache to avoid repeat callouts.
     */
    @AuraEnabled
    public static List<Row> getRecommendations(Boolean forceRefresh) {
        try {
            List<RecommendationClient.Recommendation> recs = forceRefresh == true ? null : RecommendationCache.get();
            if (recs == null) {
                recs = RecommendationClient.fetchPending();
                RecommendationCache.put(recs);
            }
            return buildRows(recs);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getRecommendations failed: ' + e.getMessage());
            throw new AuraHandledException('Unable to load AI recommendations right now.');
        }
    }

    /**
     * @description Applies accepted fields and queues outcomes for the AI service.
     */
    @AuraEnabled
    public static Map<String, Object> applyDecisions(List<Decision> decisions) {
        if (decisions == null || decisions.isEmpty()) {
            throw new AuraHandledException('Nothing to apply.');
        }
        if (decisions.size() > MAX_APPLY) {
            throw new AuraHandledException('You can apply up to ' + MAX_APPLY + ' Opportunities at a time.');
        }

        Set<Id> ids = new Set<Id>();
        for (Decision d : decisions) {
            ids.add(d.opportunityId);
        }
        Map<Id, Opportunity> current = new Map<Id, Opportunity>([
            SELECT Id, Type, Description, Forecasted_Users__c
            FROM Opportunity
            WHERE Id IN :ids
            WITH USER_MODE
        ]);

        List<Opportunity> updates = new List<Opportunity>();
        List<RecommendationOutcomeJob.Outcome> outcomes = new List<RecommendationOutcomeJob.Outcome>();

        for (Decision d : decisions) {
            Opportunity opp = current.get(d.opportunityId);
            if (opp == null) {
                continue; // user lost access or record deleted - never write
            }
            if (d.action == 'REJECT') {
                outcomes.add(new RecommendationOutcomeJob.Outcome(d.opportunityId, d.version, 'REJECTED', null));
                continue;
            }

            Opportunity upd = new Opportunity(Id = opp.Id);
            List<String> accepted = new List<String>();
            if (String.isNotBlank(d.type) && String.isBlank(opp.Type)) {
                upd.Type = d.type;
                accepted.add('Type');
            }
            if (String.isNotBlank(d.description) && String.isBlank(opp.Description)) {
                upd.Description = d.description.left(32000);
                accepted.add('Description');
            }
            if (String.isNotBlank(d.users) && (opp.Forecasted_Users__c == null || opp.Forecasted_Users__c == 0)) {
                upd.Forecasted_Users__c = Decimal.valueOf(d.users);
                accepted.add('Forecasted_Users__c');
            }
            if (!accepted.isEmpty()) {
                updates.add(upd);
                outcomes.add(new RecommendationOutcomeJob.Outcome(d.opportunityId, d.version, 'ACCEPTED', accepted));
            }
        }

        Integer saved = 0;
        if (!updates.isEmpty()) {
            for (Database.SaveResult sr : Database.update(updates, false, AccessLevel.USER_MODE)) {
                if (sr.isSuccess()) {
                    saved++;
                }
            }
        }
        if (!outcomes.isEmpty()) {
            System.enqueueJob(new RecommendationOutcomeJob(outcomes));
        }
        RecommendationCache.clear();
        return new Map<String, Object>{ 'saved' => saved, 'queuedOutcomes' => outcomes.size() };
    }

    private static List<Row> buildRows(List<RecommendationClient.Recommendation> recs) {
        Set<Id> candidateIds = new Set<Id>();
        for (RecommendationClient.Recommendation r : recs) {
            candidateIds.add(r.opportunityId);
        }
        // Security: the service may return IDs the user cannot see. USER_MODE filters them out.
        Map<Id, Opportunity> visible = new Map<Id, Opportunity>([
            SELECT Id, Name, Account.Name, Type, Description, Forecasted_Users__c
            FROM Opportunity
            WHERE Id IN :candidateIds
            WITH USER_MODE
        ]);

        List<Row> rows = new List<Row>();
        for (RecommendationClient.Recommendation r : recs) {
            Opportunity opp = visible.get(r.opportunityId);
            if (opp == null) {
                continue;
            }
            Row row = new Row();
            row.opportunityId = opp.Id;
            row.opportunityName = opp.Name;
            row.accountName = opp.Account?.Name;
            row.version = r.version;
            row.typeEditable = String.isBlank(opp.Type) && String.isNotBlank(r.suggestedType);
            row.descriptionEditable = String.isBlank(opp.Description) && String.isNotBlank(r.suggestedDescription);
            row.usersEditable = (opp.Forecasted_Users__c == null || opp.Forecasted_Users__c == 0)
                && r.usersConfidence == 'HIGH' && String.isNotBlank(r.suggestedUsers);
            if (!(row.typeEditable || row.descriptionEditable || row.usersEditable)) {
                continue; // nothing actionable -> hide row
            }
            row.suggestedType = r.suggestedType;
            row.typeReason = r.typeReason;
            row.typeConfidence = r.typeConfidence;
            row.suggestedDescription = r.suggestedDescription;
            row.suggestedUsers = r.suggestedUsers;
            rows.add(row);
        }
        return rows;
    }
}
