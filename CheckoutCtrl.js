/* this example is an angular checkout ctrl used in custom shopping cart */

function CheckoutCtrl($scope, $rootScope, $filter, $http, $location, $routeParams, stepUpdateService, regroupCartService, couponService, hotelService, billingDataService){
	$scope.steps = ['one', 'two', 'thanks']; /* url paths for checkout steps */
	
	$scope.$on('stepUpdated', function() {
	  $scope.step = stepUpdateService.step; 
	});
	
	
	/* watcher for adding a contact email */
	$scope.addEmail = function(form){
		// only add another email if the current email is filled in and valid
		if(form.$valid){
			$rootScope.billingData.emails.push({});
		}
	}
	
	/* removes an email address from data */
	$scope.removeEmail = function(index){
		if(index != 0 && index <= ($rootScope.billingData.emails.length - 1))
			$rootScope.billingData.emails.splice(index, 1); // remove from array
	}
	
	/* dynamic watcher for the credit card expiration dropdown */
	$scope.initNextSixYears = function(){
		var today = new Date();
		var currentMonth = today.getMonth() + 1;
		var currentYear = today.getFullYear();
		var firstOfMonth = new Date(currentMonth + '/1/' + currentYear);
		
		if(typeof($rootScope.billingData) != "undefined" && typeof($rootScope.billingData.cc_expiration_month) != "undefined"){
			currentMonth = $rootScope.billingData.cc_expiration_month;
		}
		
		var compareDate = new Date(currentMonth + '/1/' + currentYear);
		if(compareDate < firstOfMonth){
			currentYear += 1;
		}
		$scope.nextSixYears = [];
		for(var i = 0; i < 6; i++)
			$scope.nextSixYears.push(currentYear + i);
	}
	$scope.initNextSixYears();
	
	/* detect whether checkout requires more items */
	$scope.itemRequiresMoreInfo = function(item){
		var requiresMore = false;
		var requiredFields = ["shoe_size_required", "body_weight_required", "height_required", "lunches_required"];
		for(var i = 0; i < requiredFields.length; i++){
			var field = requiredFields[i];
			if(item.json && item.json[field]){
				requiresMore = true;
			}
		}
		return requiresMore;
	};
	
	$scope.isCurrentStep = function(step) {
	  return $scope.step === step;
	};
    
	$scope.setCurrentStep = function(step) {
	  $scope.step = step;
	};
    
	$scope.getCurrentStep = function() {
	  return $scope.steps[$scope.step];
	};
	
    
	/* handle pressing next step button */
	$scope.handleNext = function(currentForm) {

		if(typeof($scope.currentForm) != "undefined" && !$scope.currentForm.$valid){
			$scope.currentForm.$errorMessage = $scope.formErrorMessage;
			jQuery('.ng-invalid-required').removeClass('ng-pristine').addClass('ng-dirty');
			return;
		}
		$scope.currentForm.$errorMessage = null;
		if(typeof($routeParams) != "undefined" && $routeParams.step_num && $rootScope.cartItems.length == 0){
			$location.path('cart');
		}else{
			if($scope.currentForm.$valid && !$scope.isLastStep()) {
			   var stepPath = 'checkout/step' + ($scope.step + 2);
			   $location.path(stepPath);
			   $scope.saveDataToSimpleCart();
			   //$scope.sendPageView();
		    }else if($scope.isLastStep()){
				if($rootScope.billingData.agree && $scope.currentForm.$valid){
					$scope.submitCheckout();
				}
			}
		}
	};
	
	
	/* strip credit card information */
	$scope.santizeBillingDataForSave = function(){
		var data = angular.copy($rootScope.billingData);
		var banFields = ['cc_expiration_month', 'cc_expiration_year', 'cc_ccv', 'cc_number'];
		for(var i = 0; i < banFields.length; i++){
			var field = banFields[i];
			delete data[field];
		}
		return data;
	};
	
	$scope.setCurrentItem = function(item){
		$rootScope.currentItem = item;
	};
	
    $scope.initCCValidator = function(){
		CreditCardValidator.init('.ccnumber');
	};
	
	/* submit the checkout to node */
	$scope.submitCheckout = function(){
	    $scope.checkoutUrl = "//" + document.domain + "/checkout/process";
	    var data = {billingData: $scope.billingData, cartItems: $scope.cartItems, coupons: couponService.coupons};
	    $scope.processingOrder = true;
	    $scope.bookingText = "Processing Order ...";
	    
		$http.post($scope.checkoutUrl, data).success($scope.successfulCheckout).error(function(data, status, headers, config) {
		    $scope.failCheckout();
		});
	};
	
	$scope.successfulCheckout = function(data){
		if(typeof(data.authorize) == "object" && typeof(data.authorize.responsereasontext) != "undefined"){
			if(data.authorize.responsereasoncode == "1"){
				if(document.domain.toString().indexOf('discoverhawaiitours.com') != -1){
	    			$scope.flatCheckoutSuccess(data);
	    		}else{
	    			$scope.step += 1;
					$rootScope.finalBillingData = angular.copy($rootScope.billingData);
					$rootScope.finalCartItems = angular.copy($rootScope.cartItems);
					$rootScope.finalSubtotal = angular.copy($rootScope.subtotal);
					$rootScope.finalTotal = angular.copy($rootScope.total);
					$rootScope.finalTax = angular.copy($rootScope.tax);
					$rootScope.finalDiscounts = angular.copy($rootScope.discounts);
					
					// ECOMMERCE ANALYTICS TRACKING ====>
					ga('ecommerce:addTransaction', {
					  'id': data.authorize.transactionid,                     // Transaction ID. Required.
					  'affiliation': 'Discover Hawaii Tours',   // Affiliation or store name.
					  'revenue': data.billingData.subTotal,               // Grand Total.
					  'shipping': '0',                  // Shipping.
					  'tax': data.billingData.tax                   // Tax.
					});
	
					for (var i = 0; i < data.cartItems.length; i++) {
						var thisItem = data.cartItems[i];
						ga('ecommerce:addItem', {
						  'id': data.authorize.transactionid,                     // Transaction ID. Required.
						  'name': thisItem.name,    // Product name. Required.
						  'sku': thisItem.tourId,                 // SKU/code.
						  'category': 'Tours',         // Category or variation.
						  'price': thisItem.subtotal,                 // Unit price.
						  'quantity': thisItem.travelers.length                   // Quantity.
						});
					};
					ga('ecommerce:send');
					// <==== END ECOMMERCE ANALYTICS TRACKING 
	
					$scope.currentForm.$wasCardError = false;
					simpleCart.empty();
					simpleCart.save();
					$scope.$$phase || $scope.$apply();
					$scope.sendPageView('checkout/thanks');
					$location.path('checkout/thanks');
	    		}
				
			}else{
				$scope.failCheckout("Sorry, there were problems processing your card. " + data.authorize.responsereasontext + " ");
			}
		}else{
			$scope.failCheckout("Sorry, there were problems processing your card. ");
		}
	};
	
	$scope.async = function(url){
			//this is just a utility function to load external scripts async
				jQuery('body').append('<script type="text/javascript" src="'+url+'"></script>');
	};


	$scope.failCheckout = function(msg){
		if(typeof(msg) != "string"){
			msg = "Sorry, your order could not be processed at this time. Please check your payment details and try again.";
		}
		msg = msg + $scope.defaultFailMessage;
		jQuery('#submitfailure').html('<p>'+msg+'</p>');
		jQuery('#submitfailure').slideDown();
		var copiedData = angular.copy($scope.billingData);
		delete copiedData.cc_number;
		delete copiedData.cc_expiration_month;
		delete copiedData.cc_expiration_year;
		delete copiedData.cc_ccv;
		Exceptional.handle('Could not connect to checkout node for this customer:' + JSON.stringify(copiedData),
			               'CheckoutCtrl.js');
		$scope.processingOrder = false;
		$scope.bookingText = 'Complete Booking';
		$scope.currentForm.$errorMessage = msg;
		//$scope.currentForm.$setValidity(false);
		$scope.currentForm.$wasCardError = true;
		$scope.$$phase || $scope.$apply();
	};
	
	$scope.isCheckout = true;
	
	$scope.setStartStep = function(){
		var isFlatThanksPage = window.location.toString().indexOf('thank-you') != -1;
		if($routeParams.step_num){
			var stepNum;
			if($routeParams.step_num.indexOf('thank') == -1){ // could be thank-you or #thanks
				stepNum = parseInt($routeParams.step_num.replace('step', ''));
			}else{
				if(isFlatThanksPage || (typeof($rootScope.finalTotal) != "undefined" && $rootScope.finalTotal)){	
					stepNum = $scope.steps.length; // go to last step, non-zero index to match path indexing
				}else{
					//console.log("should redirect to the cart");
					return window.location = "checkout/#/cart"; // go to the cart in this case
				}
			}
			if(stepNum && stepNum <= $scope.steps.length){
				$scope.step = stepNum - 1;
			}
		}else{
			$scope.step = 0;
			$location.path('checkout/step1');
		}
	};
	$scope.setStartStep();
	
	$scope.maskCC = function($event){
		var value = jQuery($event.currentTarget).inputmask("unmaskedvalue");
		var parsedCCNumber = value.replace(/ /g,"");
		$scope.currentForm.ccnumber.$setViewValue(parsedCCNumber); // fix view value from input mask
		jQuery(".cards li").removeClass('on');
		if(parsedCCNumber.length > 15){
			jQuery($event.currentTarget).validateCreditCard(function(result){
				$scope.onValidateCreditCard(result, '.ccnumber', $event.currentTarget);
			});
		}
	};
	
	/* credit card validation for onkeyup */
	$scope.onValidateCreditCard = function(result, selector, element){
        if((result.card_type && result.length_valid && result.luhn_valid)){
	        var cardName = result.card_type.name;
	        $scope.setSelectedCard(element, cardName);
            jQuery(element).removeClass('ng-invalid').addClass('ng-valid').removeClass('ng-pristine').addClass('ng-dirty');
            jQuery(element).removeClass('ng-invalid-required').addClass('ng-valid-required');
            angular.element(selector).scope().currentForm.ccnumber.$valid = true;
            angular.element(selector).scope().$$phase || angular.element(selector).scope().$apply();
        }else{
            jQuery(element).addClass('ng-invalid').removeClass('ng-valid');
        }
	};
    
	$scope.maskPhone = function($event){
		var value = jQuery($event.currentTarget).inputmask("unmaskedvalue").replace(/ /g,"");
		$scope.currentForm.cell.$setViewValue(value); // fix problem with jquery plugin not setting view value
	};
	
	
	/* send google analytics pageview */
	$scope.sendPageView = function(path){
		var title = 'Checkout Step ' + ($scope.step + 1);
		var page = "/checkout/#/";
		if(typeof(path) == "undefined"){
			page += 'checkout/step' + ($scope.step + 1);
		}else{
			if(path.indexOf('thanks') != -1){
				title += ' - Confirmation Page';
			}
			page += path;
		}
		ga('send', 'pageview', {
		  'page': page,
		  'title': title
		});
	}
	$scope.sendPageView();

	$scope.hotelService = hotelService;
	regroupCartService.regroup();
}
CheckoutCtrl.$inject = ['$scope', '$rootScope', '$filter', '$http', '$location', '$routeParams', 'stepUpdateService', 'regroupCartService', 'couponService', 'hotelService', 'billingDataService'];
discoverModule.controller('CheckoutCtrl', CheckoutCtrl);
