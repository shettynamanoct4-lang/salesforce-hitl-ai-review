import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRecommendations from '@salesforce/apex/AiRecommendationController.getRecommendations';
import applyDecisions from '@salesforce/apex/AiRecommendationController.applyDecisions';

const MAX_SELECTED = 10;

export default class AiRecommendationReview extends LightningElement {
    @track rows = [];
    isLoading = false;
    error;

    connectedCallback() {
        this.load(false);
    }

    get selectedCount() {
        return this.rows.filter((r) => r.selected).length;
    }

    get applyDisabled() {
        return this.isLoading || this.selectedCount === 0 || this.selectedCount > MAX_SELECTED;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get limitMessage() {
        return this.selectedCount > MAX_SELECTED ? `Select up to ${MAX_SELECTED} Opportunities to apply.` : '';
    }

    async load(forceRefresh) {
        this.isLoading = true;
        this.error = undefined;
        try {
            const data = await getRecommendations({ forceRefresh });
            this.rows = data.map((r) => ({
                ...r,
                selected: false,
                draftType: r.suggestedType,
                draftDescription: r.suggestedDescription,
                draftUsers: r.suggestedUsers,
                confidenceClass: r.typeConfidence === 'HIGH' ? 'slds-badge slds-theme_success' : 'slds-badge'
            }));
        } catch (e) {
            this.error = e?.body?.message || 'Unable to load recommendations.';
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        this.load(true);
    }

    handleSelect(event) {
        this.updateRow(event.target.dataset.id, { selected: event.target.checked });
    }

    handleDraftChange(event) {
        const { id, field } = event.target.dataset;
        this.updateRow(id, { [field]: event.target.value });
    }

    async handleApply() {
        const decisions = this.rows
            .filter((r) => r.selected)
            .map((r) => ({
                opportunityId: r.opportunityId,
                version: r.version,
                action: 'ACCEPT',
                type: r.typeEditable ? r.draftType : null,
                description: r.descriptionEditable ? r.draftDescription : null,
                users: r.usersEditable ? r.draftUsers : null
            }));
        await this.submit(decisions, 'Changes saved');
    }

    async handleReject(event) {
        const row = this.rows.find((r) => r.opportunityId === event.target.dataset.id);
        await this.submit([{ opportunityId: row.opportunityId, version: row.version, action: 'REJECT' }], 'Recommendation dismissed');
    }

    async submit(decisions, successTitle) {
        this.isLoading = true;
        try {
            const result = await applyDecisions({ decisions });
            this.dispatchEvent(new ShowToastEvent({ title: successTitle, message: `${result.saved} record(s) updated`, variant: 'success' }));
            await this.load(true);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: e?.body?.message, variant: 'error' }));
        } finally {
            this.isLoading = false;
        }
    }

    updateRow(id, changes) {
        this.rows = this.rows.map((r) => (r.opportunityId === id ? { ...r, ...changes } : r));
    }
}
