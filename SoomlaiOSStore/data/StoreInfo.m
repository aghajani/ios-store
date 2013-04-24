/*
 * Copyright (C) 2012 Soomla Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "StoreInfo.h"
#import "StorageManager.h"
#import "KeyValDatabase.h"
#import "JSONKit.h"
#import "JSONConsts.h"
#import "VirtualCategory.h"
#import "VirtualGood.h"
#import "VirtualCurrency.h"
#import "VirtualCurrencyPack.h"
#import "NonConsumableItem.h"
#import "VirtualItemNotFoundException.h"
#import "StoreEncryptor.h"
#import "AppStoreItem.h"
#import "ObscuredNSUserDefaults.h"
#import "StoreUtils.h"
#import "PurchaseType.h"
#import "PurchaseWithMarket.h"
#import "PurchaseWithVirtualItem.h"
#import "SingleUseVG.h"
#import "LifetimeVG.h"
#import "EquippableVG.h"
#import "SingleUsePackVG.h"
#import "UpgradeVG.h"

@implementation StoreInfo

@synthesize virtualCategories, virtualCurrencies, virtualCurrencyPacks, virtualGoods, nonConsumableItems, virtualItems, purchasableItems, goodsCategories;

static NSString* TAG = @"SOOMLA StoreInfo";

+ (StoreInfo*)getInstance{
    static StoreInfo* _instance = nil;
    
    @synchronized( self ) {
        if( _instance == nil ) {
            _instance = [[StoreInfo alloc ] init];
        }
    }
    
    return _instance;
}

- (void)checkAndAddPurchasable:(PurchasableVirtualItem*)pvi toTempPurchasables:(NSMutableDictionary*)tmpPurchasableItems {
    PurchaseType* purchaseType = pvi.purchaseType;
    if ([purchaseType isKindOfClass:[PurchaseWithMarket class]]) {
        [tmpPurchasableItems setObject:pvi forKey:((PurchaseWithMarket*) purchaseType).appStoreItem.productId];
    }
}

- (void)addVirtualGood:(VirtualGood*)good withTempGoods:(NSMutableArray*)tmpGoods andTempItems:(NSMutableDictionary*)tmpVirtualItems andTempPurchasables:(NSMutableDictionary*)tmpPurchasableItems{
    [tmpGoods addObject:good];
    
    [tmpVirtualItems setObject:good forKey:good.itemId];
    
    [self checkAndAddPurchasable:good toTempPurchasables:tmpPurchasableItems];
}

- (void)privInitializeWithIStoreAssets:(id)storeAssets {
    self.virtualGoods = [storeAssets virtualGoods];
    self.virtualCurrencies = [storeAssets virtualCurrencies];
    self.virtualCurrencyPacks = [storeAssets virtualCurrencyPacks];
    self.virtualCategories = [storeAssets virtualCategories];
    self.nonConsumableItems = [storeAssets nonConsumableItems];
    
    NSMutableDictionary* tmpVirtualItems = [NSMutableDictionary dictionary];
    NSMutableDictionary* tmpPurchasableItems = [NSMutableDictionary dictionary];
    NSMutableDictionary* tmpGoodsCategories = [NSMutableDictionary dictionary];
    
    for(VirtualCurrency* vi in self.virtualCurrencies) {
        [tmpVirtualItems setObject:vi forKey:vi.itemId];
    }
    
    for(VirtualCurrencyPack* vi in self.virtualCurrencyPacks) {
        [tmpVirtualItems setObject:vi forKey:vi.itemId];
        
        [self checkAndAddPurchasable:vi toTempPurchasables:tmpPurchasableItems];
    }
    
    for(VirtualGood* vi in self.virtualGoods) {
        [tmpVirtualItems setObject:vi forKey:vi.itemId];
        
        [self checkAndAddPurchasable:vi toTempPurchasables:tmpPurchasableItems];
    }
    
    for(NonConsumableItem* vi in self.nonConsumableItems) {
        [tmpVirtualItems setObject:vi forKey:vi.itemId];

        [self checkAndAddPurchasable:vi toTempPurchasables:tmpPurchasableItems];
    }
    
    for(VirtualCategory* category in self.virtualCategories) {
        for(VirtualGood* good in category.goods) {
            [tmpGoodsCategories setObject:category forKey:good.itemId];
        }
    }
    
    self.virtualItems = tmpVirtualItems;
    self.purchasableItems = tmpPurchasableItems;
    self.goodsCategories = tmpGoodsCategories;
    
    // put StoreInfo in the database as JSON
    NSString* storeInfoJSON = [[self toDictionary] JSONString];
    NSString* ec = [[NSString alloc] initWithData:[storeInfoJSON dataUsingEncoding:NSUTF8StringEncoding] encoding:NSUTF8StringEncoding];
    NSString* enc = [StoreEncryptor encryptString:ec];
    NSString* key = [StoreEncryptor encryptString:[KeyValDatabase keyMetaStoreInfo]];
    [[[StorageManager getInstance] kvDatabase] setVal:enc forKey:key];
}

- (void)initializeWithIStoreAsssets:(id <IStoreAsssets>)storeAssets{
    if(storeAssets == NULL){
        LogError(TAG, @"The given store assets can't be null !");
        return;
    }
    
    // we prefer initialization from the database (storeAssets are only set on the first time the game is loaded)!
    if (![self initializeFromDB]){
        [self privInitializeWithIStoreAssets:storeAssets];
    }
}

- (BOOL)initializeFromDB{
    NSString* key = [StoreEncryptor encryptString:[KeyValDatabase keyMetaStoreInfo]];
    NSString* storeInfoJSON = [[[StorageManager getInstance] kvDatabase] getValForKey:key];
    
    if(!storeInfoJSON || [storeInfoJSON length] == 0){
        LogDebug(TAG, @"store json is not in DB yet.")
        return NO;
    }
    
    @try {
        storeInfoJSON = [StoreEncryptor decryptToString:storeInfoJSON];
    } @catch (NSException* ex){
        LogError(TAG, @"An error occured while trying to decrypt store info JSON.");
        return NO;
    }
    
    LogDebug(TAG, ([NSString stringWithFormat:@"the metadata-economy json (from DB) is %@", storeInfoJSON]));
   
    @try {

        NSDictionary* storeInfo = [storeInfoJSON objectFromJSONString];
        
        NSMutableDictionary* tmpVirtualItems = [NSMutableDictionary dictionary];
        NSMutableDictionary* tmpPurchasableItems = [NSMutableDictionary dictionary];
        NSMutableDictionary* tmpGoodsCategories = [NSMutableDictionary dictionary];
        
        NSMutableArray* currencies = [[NSMutableArray alloc] init];
        NSArray* currenciesDicts = [storeInfo objectForKey:JSON_STORE_CURRENCIES];
        for(NSDictionary* currencyDict in currenciesDicts){
            VirtualCurrency* o = [[VirtualCurrency alloc] initWithDictionary: currencyDict];
            [currencies addObject:o];
            
            [tmpVirtualItems setObject:o forKey:o.itemId];
        }
        self.virtualCurrencies = currencies;
        
        NSMutableArray* currencyPacks = [[NSMutableArray alloc] init];
        NSArray* currencyPacksDicts = [storeInfo objectForKey:JSON_STORE_CURRENCYPACKS];
        for(NSDictionary* currencyPackDict in currencyPacksDicts){
            VirtualCurrencyPack* o = [[VirtualCurrencyPack alloc] initWithDictionary: currencyPackDict];
            [currencyPacks addObject:o];
            
            [tmpVirtualItems setObject:o forKey:o.itemId];
            
            [self checkAndAddPurchasable:o toTempPurchasables:tmpPurchasableItems];
        }
        self.virtualCurrencyPacks = currencyPacks;
        
        
        NSDictionary* goodsDict = [storeInfo objectForKey:JSON_STORE_GOODS];
        NSArray* suGoods = [goodsDict objectForKey:JSON_STORE_GOODS_SU];
        NSArray* ltGoods = [goodsDict objectForKey:JSON_STORE_GOODS_LT];
        NSArray* eqGoods = [goodsDict objectForKey:JSON_STORE_GOODS_EQ];
        NSArray* upGoods = [goodsDict objectForKey:JSON_STORE_GOODS_UP];
        NSArray* paGoods = [goodsDict objectForKey:JSON_STORE_GOODS_PA];
        NSMutableArray* goods = [[NSMutableArray alloc] init];
        for(NSDictionary* gDict in suGoods){
            SingleUseVG* g = [[SingleUseVG alloc] initWithDictionary: gDict];
            [self addVirtualGood:g withTempGoods:goods andTempItems:tmpVirtualItems andTempPurchasables:tmpPurchasableItems];
        }
        for(NSDictionary* gDict in ltGoods){
            LifetimeVG* g = [[LifetimeVG alloc] initWithDictionary: gDict];
            [self addVirtualGood:g withTempGoods:goods andTempItems:tmpVirtualItems andTempPurchasables:tmpPurchasableItems];
        }
        for(NSDictionary* gDict in eqGoods){
            EquippableVG* g = [[EquippableVG alloc] initWithDictionary: gDict];
            [self addVirtualGood:g withTempGoods:goods andTempItems:tmpVirtualItems andTempPurchasables:tmpPurchasableItems];
        }
        for(NSDictionary* gDict in upGoods){
            UpgradeVG* g = [[UpgradeVG alloc] initWithDictionary: gDict];
            [self addVirtualGood:g withTempGoods:goods andTempItems:tmpVirtualItems andTempPurchasables:tmpPurchasableItems];
        }
        for(NSDictionary* gDict in paGoods){
            SingleUsePackVG* g = [[SingleUsePackVG alloc] initWithDictionary: gDict];
            [self addVirtualGood:g withTempGoods:goods andTempItems:tmpVirtualItems andTempPurchasables:tmpPurchasableItems];
        }
        self.virtualGoods = goods;
        
        NSMutableArray* categories = [[NSMutableArray alloc] init];
        NSArray* categoriesDicts = [storeInfo objectForKey:JSON_STORE_CATEGORIES];
        for(NSDictionary* categoryDict in categoriesDicts){
            VirtualCategory* c = [[VirtualCategory alloc] initWithDictionary: categoryDict];
            [categories addObject:c];
            
            for(VirtualGood* good in c.goods) {
                [tmpGoodsCategories setObject:c forKey:good.itemId];
            }
        }
        self.virtualCategories = categories;
        
        NSMutableArray* nonConsumables = [[NSMutableArray alloc] init];
        NSArray* nonConsumableItemsDict = [storeInfo objectForKey:JSON_STORE_NONCONSUMABLES];
        for(NSDictionary* nonConsumableItemDict in nonConsumableItemsDict){
            NonConsumableItem* non = [[NonConsumableItem alloc] initWithDictionary:nonConsumableItemDict];
            [nonConsumables addObject:non];
            
            [tmpVirtualItems setObject:non forKey:non.itemId];
            
            [self checkAndAddPurchasable:non toTempPurchasables:tmpPurchasableItems];
        }
        self.nonConsumableItems = nonConsumables;
        
        self.virtualItems = tmpVirtualItems;
        self.purchasableItems = tmpPurchasableItems;
        self.goodsCategories = tmpGoodsCategories;
        
        // everything went well... StoreInfo is initialized from the local DB.
        // it's ok to return now.
        
        return YES;
    } @catch (NSException* ex) {
        LogError(TAG, @"An error occured while trying to parse store info JSON.");
    }
    
    return NO;
}

- (NSDictionary*)toDictionary{
    
    NSMutableArray* currencies = [NSMutableArray array];
    for(VirtualCurrency* c in self.virtualCurrencies){
        [currencies addObject:[c toDictionary]];
    }
    
    NSMutableArray* packs = [NSMutableArray array];
    for(VirtualCurrencyPack* c in self.virtualCurrencyPacks){
        [packs addObject:[c toDictionary]];
    }
    
    NSMutableArray* suGoods = [NSMutableArray array];
    NSMutableArray* ltGoods = [NSMutableArray array];
    NSMutableArray* eqGoods = [NSMutableArray array];
    NSMutableArray* upGoods = [NSMutableArray array];
    NSMutableArray* paGoods = [NSMutableArray array];
    for(VirtualGood* g in self.virtualGoods){
        if ([g isKindOfClass:[SingleUseVG class]]) {
            [suGoods addObject:[g toDictionary]];
        } else if ([g isKindOfClass:[EquippableVG class]]) {
            [eqGoods addObject:[g toDictionary]];
        } else if ([g isKindOfClass:[LifetimeVG class]]) {
            [ltGoods addObject:[g toDictionary]];
        } else if ([g isKindOfClass:[SingleUsePackVG class]]) {
            [paGoods addObject:[g toDictionary]];
        } else if ([g isKindOfClass:[UpgradeVG class]]) {
            [upGoods addObject:[g toDictionary]];
        }
    }
    NSDictionary* goods = [NSDictionary dictionaryWithObjectsAndKeys:
                           suGoods, JSON_STORE_GOODS_SU,
                           ltGoods, JSON_STORE_GOODS_LT,
                           eqGoods, JSON_STORE_GOODS_EQ,
                           upGoods, JSON_STORE_GOODS_UP,
                           paGoods, JSON_STORE_GOODS_PA, nil];

    NSMutableArray* categories = [NSMutableArray array];
    for(VirtualCategory* c in self.virtualCategories){
        [categories addObject:[c toDictionary]];
    }
    
    NSMutableArray* nonConsumables = [NSMutableArray array];
    for(NonConsumableItem* non in self.nonConsumableItems) {
        [nonConsumables addObject:[non toDictionary]];
    }
    
    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
    
    [dict setObject:categories forKey:JSON_STORE_CATEGORIES];
    [dict setObject:currencies forKey:JSON_STORE_CURRENCIES];
    [dict setObject:packs forKey:JSON_STORE_CURRENCYPACKS];
    [dict setObject:goods forKey:JSON_STORE_GOODS];
    [dict setObject:nonConsumables forKey:JSON_STORE_NONCONSUMABLES];
    
    return dict;
}

- (VirtualItem*)virtualItemWithId:(NSString*)itemId {
    VirtualItem* vi = [self.virtualItems objectForKey:itemId];
    if (!vi) {
        @throw [[VirtualItemNotFoundException alloc] initWithLookupField:@"itemId" andLookupValue:itemId];
    }
    
    return vi;
}

- (PurchasableVirtualItem*)purchasableItemWithProductId:(NSString*)productId {
    PurchasableVirtualItem* pvi = [self.purchasableItems objectForKey:productId];
    if (!pvi) {
        @throw [[VirtualItemNotFoundException alloc] initWithLookupField:@"productId" andLookupValue:productId];
    }
    
    return pvi;
}

- (VirtualCategory*)categoryForGoodWithItemId:(NSString*)goodItemId {
    VirtualCategory* cat = [self.goodsCategories objectForKey:goodItemId];

    if (!cat) {
        @throw [[VirtualItemNotFoundException alloc] initWithLookupField:@"goodItemId" andLookupValue:goodItemId];
    }
    
    return cat;
}

@end
