import ballerina/http;
import ballerina/io;
import ballerina/workflow;
import ballerina/workflow.management;

import ballerina/workflow.management.rest as _;
import hasitha/workflow.runtime.bridge as _;

service /expenses on new http:Listener(9096) {

    # Submits an expense claim and starts its approval workflow.
    #
    # + claim - The expense claim
    # + return - The workflow identifier used as the claim reference, or an error
    resource function post .(ExpenseClaim claim) returns json|error {
        string workflowId = check workflow:run(expenseApprovalWorkflow, claim);
        return {claimId: claim.claimId, workflowId, status: "PENDING_REVIEW"};
    }

    # Submits the supporting bills for a claim; the workflow is durably waiting on them
    # after the manager requests the bills.
    #
    # + workflowId - The workflow identifier returned when the claim was submitted
    # + submission - The bills
    # + return - A confirmation, or an error
    resource function post [string workflowId]/bills(BillSubmission submission) returns json|error {
        check workflow:sendData(expenseApprovalWorkflow, workflowId, "billSubmitted", submission);
        return {workflowId, status: "BILLS_SUBMITTED"};
    }

    # Reads the outcome of a claim's workflow.
    #
    # + workflowId - The workflow identifier returned when the claim was submitted
    # + return - The workflow result and status, or an error
    resource function get [string workflowId]() returns json|error {
        management:WorkflowExecutionInfo info = check management:getWorkflowInfo(workflowId);
        if info.status == "RUNNING" {
            return {workflowId, status: "IN_REVIEW"};
        }
        anydata result = check workflow:getWorkflowResult(workflowId, 30);
        return {workflowId, result: check result.cloneWithType(json)};
    }
}

# Prints the endpoints once the worker and service are up.
#
# + return - An error when startup fails
public function main() returns error? {
    io:println("Expense approval service listening on http://localhost:9096/expenses");
    io:println("  1. Submit claim: curl -X POST localhost:9096/expenses -H 'Content-Type: application/json' -d '{\"claimId\":\"EXP-1\",\"employee\":\"nimal\",\"amount\":180.50,\"currency\":\"EUR\",\"purpose\":\"Team lunch\"}'");
    io:println("     -> note the workflowId in the response; it is the claim reference below");
    io:println("  2. Decide the checkExpenseRequest task in the ICP inbox (role: manager)");
    io:println("  3. Submit bills: curl -X POST localhost:9096/expenses/<workflowId>/bills -H 'Content-Type: application/json' -d '{\"bills\":[{\"reference\":\"BILL-9\",\"amount\":180.50}]}'");
    io:println("  4. Decide the reviewBills task in the ICP inbox (role: manager)");
    io:println("  5. Status: curl localhost:9096/expenses/<workflowId>");
}
