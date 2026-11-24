@IsTest
private class AiRecommendationControllerTest {

    private class ServiceMock implements HttpCalloutMock {
        private final String body;
        ServiceMock(String body) { this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(req.getEndpoint().endsWith('/outcome') ? '{"status":"ok"}' : body);
            return res;
        }
    }

    @TestSetup
    static void setup() {
        insert new AI_Review_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(),
            Base_Url__c = 'https://ai-review.example.run.app', Enabled__c = true);
        Account acc = new Account(Name = 'Acme');
        insert acc;
        insert new List<Opportunity>{
            new Opportunity(Name = 'Blank Opp', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addDays(30)),
            new Opportunity(Name = 'Filled Opp', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
                Type = 'New Business', Description = 'Human notes', Forecasted_Users__c = 25)
        };
    }

    private static String serviceBody() {
        List<String> rows = new List<String>();
        for (Opportunity o : [SELECT Id FROM Opportunity]) {
            rows.add('{"opportunityId":"' + o.Id + '","version":"v1","suggestedType":"Existing Business",'
                + '"typeReason":"Customer expanding","typeConfidence":"HIGH","suggestedDescription":"Expansion call",'
                + '"suggestedUsers":"50","usersConfidence":"HIGH"}');
        }
        return '{"recommendations":[' + String.join(rows, ',') + ']}';
    }

    @IsTest
    static void hidesRowsWithOnlyProtectedFields() {
        Test.setMock(HttpCalloutMock.class, new ServiceMock(serviceBody()));
        Test.startTest();
        List<AiRecommendationController.Row> rows = AiRecommendationController.getRecommendations(true);
        Test.stopTest();
        Assert.areEqual(1, rows.size(), 'Only the Opportunity with blank fields is actionable');
        Assert.areEqual('Blank Opp', rows[0].opportunityName);
    }

    @IsTest
    static void appliesAcceptedFieldsAndNeverOverwritesHumanData() {
        Test.setMock(HttpCalloutMock.class, new ServiceMock(serviceBody()));
        List<AiRecommendationController.Decision> decisions = new List<AiRecommendationController.Decision>();
        for (Opportunity o : [SELECT Id FROM Opportunity]) {
            AiRecommendationController.Decision d = new AiRecommendationController.Decision();
            d.opportunityId = o.Id;
            d.version = 'v1';
            d.action = 'ACCEPT';
            d.type = 'Existing Business';
            d.description = 'Expansion call';
            d.users = '50';
            decisions.add(d);
        }

        Test.startTest();
        Map<String, Object> result = AiRecommendationController.applyDecisions(decisions);
        Test.stopTest();

        Assert.areEqual(1, result.get('saved'));
        Opportunity filled = [SELECT Type, Description, Forecasted_Users__c FROM Opportunity WHERE Name = 'Filled Opp'];
        Assert.areEqual('New Business', filled.Type, 'Human-entered Type must be protected');
        Assert.areEqual(25, filled.Forecasted_Users__c, 'Positive forecast must be protected');
        Opportunity blank = [SELECT Type, Forecasted_Users__c FROM Opportunity WHERE Name = 'Blank Opp'];
        Assert.areEqual('Existing Business', blank.Type);
        Assert.areEqual(50, blank.Forecasted_Users__c);
    }

    @IsTest
    static void rejectsTooManyDecisions() {
        List<AiRecommendationController.Decision> decisions = new List<AiRecommendationController.Decision>();
        for (Integer i = 0; i <= AiRecommendationController.MAX_APPLY; i++) {
            decisions.add(new AiRecommendationController.Decision());
        }
        try {
            AiRecommendationController.applyDecisions(decisions);
            Assert.fail('Expected limit error');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage());
        }
    }
}
