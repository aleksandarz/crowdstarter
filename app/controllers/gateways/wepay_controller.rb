class Gateways::WepayController < ApplicationController
  def checkout
    contribution = current_user.contributions.find(params[:contribution_id].to_i)
    project_owner = contribution.project.user
    wp_params = {
           :account_id => project_owner.wepay_account_id,
           :amount => contribution.amount,
           :short_description => "Contribution to Project ##{contribution.project.id} - #{contribution.project.name}",
           :type => "GOODS",
           :reference_id => "contribution-#{contribution.id}",
           :app_fee => contribution.amount * (SETTINGS.fee_percentage/100.0),
           :fee_payer => "Payee",
           :redirect_uri => gateways_wepay_finish_url,
           :auto_capture => 0,
           :require_shipping => 0,
      }
    wp_params.merge!(:callback_uri => gateways_wepay_ipn_url) unless Rails.env.development?
    logger.tagged("wepay params") { logger.info wp_params.inspect }
    checkout = project_owner.wepay.get('/v2/checkout/create', :params => wp_params).parsed
    logger.tagged("wepay response") { logger.info checkout.inspect }
    if checkout["checkout_id"] > 0
      contribution.update_attribute :wepay_checkout_id, checkout["checkout_id"]
      redirect_to checkout["checkout_uri"]
    else
      flash[:error] = "Payment processing failed."
      redirect_to contribution.project
    end
  end

  def finish
    contribution = current_user.contributions.find_by_wepay_checkout_id(params[:checkout_id])
    if contribution
      checkout = current_user.wepay.get('/v2/checkout/',
                                        :params => {
                                          :checkout_id =>
                                            contribution.wepay_checkout_id}).parsed
      logger.tagged("wepay response") { logger.info checkout.inspect }
      case checkout["state"]
      when "authorized"
        contribution.authorize!
        flash[:info] = "Thank you! Your contribution will finish processing shortly."
      when "reserved"
        contribution.authorize!
        contribution.approve!
        flash[:success] = "Your contribution has been recorded!"
      else
        flash[:error] = "An error occured processing the contribution."
      end
      redirect_to contribution.project
    else
      flash[:error] = "There is no record for that contribution."
      redirect_to :root
    end
  end

  def ipn
    contribution = Contribution.find_by_wepay_checkout_id(params[:checkout_id])
    if contribution.authorized?
      checkout = contribution.user.wepay.get('/v2/checkout/', :params => {:checkout_id => contribution.wepay_checkout_id}).parsed
      logger.tagged("wepay response") { logger.info checkout.inspect }
      case checkout["state"]
      when "reserved"
        contribution.reserve!
        status = "OK"
      end
    else
      status = "Already processed"
      logger.error "Contribution is in state #{contribution.workflow_state}, not authorized"
    end
    render :json => {:status => status}
  end
end