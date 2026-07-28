import React, { useState, useMemo } from 'react';
import { 
  ShoppingBag, Users, Info, Phone, Plus, Minus, 
  ChevronRight, CheckCircle, Package, X, Beer, Sun, Tv
} from 'lucide-react';

export default function App() {
  const [activeTab, setActiveTab] = useState('menu'); 
  
  const [selectedCustomItem, setSelectedCustomItem] = useState(null);
  const [pizzaCrust, setPizzaCrust] = useState('Traditional Old Forge Thick-Crust');
  const [wingSauce, setWingSauce] = useState('House Mild Sauce');

  const [cart, setCart] = useState([]);
  const [isCartOpen, setIsCartOpen] = useState(false);

  const [cateringForm, setCateringForm] = useState({
    name: '', email: '', phone: '', date: '', guests: 20, location: 'basement', notes: ''
  });
  const [cateringSubmitted, setCateringSubmitted] = useState(false);
  const [contactSubmitted, setContactSubmitted] = useState(false);

  const menuData = {
    pizza: [
      { id: 'p1', name: 'Old Forge Red Tray (12 Cuts)', price: 18.50, desc: 'Signature rectangular thick-crust. Crispy bottom, pillowy center, secret blend of cheeses.', tag: 'Famous', type: 'pizza' },
      { id: 'p2', name: 'Old Forge White Tray (12 Cuts)', price: 21.00, desc: 'Double-crust pizza stuffed with a savory herb and cheese blend, topped with rosemary and sea salt.', type: 'pizza' },
      { id: 'p3', name: 'The Enola Special Tray', price: 23.50, desc: 'Red tray loaded with house-roasted porketta, green peppers, and sharp onions.', tag: 'Local Favorite', type: 'pizza' },
      { id: 'p4', name: 'Personal Red Pizza (4 Cuts)', price: 8.50, desc: 'Smaller 4-cut version of our famous rectangular Old Forge style red tray.', type: 'pizza' },
      { id: 'p5', name: 'The Meat Tray', price: 24.50, desc: 'Red tray loaded with pepperoni, sausage, bacon, and ham.', type: 'pizza' }
    ],
    wings: [
      { id: 'w1', name: 'Jumbo Wings (10 Count)', price: 14.95, desc: 'Fresh, never frozen. Crisp fried and tossed in your custom signature house flavor.', tag: 'Best Seller', type: 'wings' },
      { id: 'w2', name: 'Jumbo Wings (20 Count)', price: 28.50, desc: 'Perfect for sharing. Choose up to two custom signature wing sauces.', type: 'wings' },
      { id: 'w3', name: 'Boneless Wing Platter', price: 12.50, desc: 'All-white meat breast chunks breaded, fried golden, and tossed in your favorite sauce.', type: 'wings' }
    ],
    subs: [
      { id: 's1', name: 'Famous Italian Porketta Sub', price: 12.00, desc: 'Slow-roasted seasoned pork, shredded and topped with melted provolone on a toasted roll.', tag: 'House Specialty', type: 'item' },
      { id: 's2', name: 'Classic Italian Hoagie', price: 11.50, desc: 'Ham, capicola, salami, provolone, lettuce, tomato, onion, and house vinaigrette.', type: 'item' },
      { id: 's3', name: 'Meatball Parm Sub', price: 12.00, desc: 'House-made Italian meatballs smothered in marinara and melted mozzarella.', type: 'item' },
      { id: 's4', name: 'Chicken Cheesesteak', price: 12.50, desc: 'Finely chopped chicken breast with melted American cheese, onions, and sauce.', type: 'item' }
    ],
    appetizers: [
      { id: 'a1', name: 'Jigsy Fries', price: 6.50, desc: 'Crispy golden fries tossed in our custom house seasoning blend.', type: 'item' },
      { id: 'a2', name: 'Mozzarella Sticks (6 Count)', price: 8.00, desc: 'Battered mozzarella sticks fried crisp, served with a side of warm marinara.', type: 'item' },
      { id: 'a3', name: 'Onion Rings', price: 7.50, desc: 'Thick-cut, beer-battered onion rings served with Texas petal dipping sauce.', type: 'item' },
      { id: 'a4', name: 'Pierogies (4 Count)', price: 7.00, desc: 'Classic PA coal-country style pierogies sautéed with butter and sweet onions.', tag: 'PA Classic', type: 'item' }
    ],
    brews: [
      { id: 'b1', name: 'Big J Double IPA (4-Pack To-Go)', price: 16.00, desc: '8.2% ABV. Heavy citrus and pine hop profile with a smooth, malty backbone.', tag: 'Brewed On-Site', type: 'item' },
      { id: 'b2', name: 'Citra Wheat Ale (4-Pack To-Go)', price: 14.00, desc: '5.4% ABV. Crisp, refreshing American wheat beer bursting with bright tropical notes.', tag: 'Brewed On-Site', type: 'item' },
      { id: 'b3', name: 'Enola Amber Lager (4-Pack To-Go)', price: 14.00, desc: '5.0% ABV. Smooth, toasted malt character with a clean, classic finish.', type: 'item' }
    ]
  };

  const cartTotal = useMemo(() => {
    return cart.reduce((sum, item) => sum + (item.price * item.quantity), 0);
  }, [cart]);

  const totalCartCount = useMemo(() => {
    return cart.reduce((sum, item) => sum + item.quantity, 0);
  }, [cart]);

  const handleAddClick = (item) => {
    if (item.type === 'pizza' || item.type === 'wings') {
      setSelectedCustomItem(item);
    } else {
      addToCartDirect(item, 'Standard Setup');
    }
  };

  const addToCartDirect = (item, customizedDetails) => {
    setCart(prev => {
      const uniqueId = `${item.id}-${customizedDetails.replace(/\s+/g, '')}`;
      const existingIndex = prev.findIndex(i => i.cartKey === uniqueId);
      
      if (existingIndex > -1) {
        const updated = [...prev];
        updated[existingIndex].quantity += 1;
        return updated;
      }
      return [...prev, { ...item, cartKey: uniqueId, details: customizedDetails, quantity: 1 }];
    });
    setSelectedCustomItem(null);
  };

  const handleModifyQuantity = (cartKey, delta) => {
    setCart(prev => {
      return prev.map(item => {
        if (item.cartKey === cartKey) {
          const newQty = item.quantity + delta;
          return newQty <= 0 ? null : { ...item, quantity: newQty };
        }
        return item;
      }).filter(Boolean);
    });
  };

  return (
    <div className="min-h-screen bg-[#121212] text-[#F3F4F6] font-sans antialiased flex flex-col max-w-md mx-auto relative shadow-2xl border-x border-neutral-900 overflow-x-hidden">
      
      {/* TOP HEADER */}
      <header className="sticky top-0 z-40 bg-[#1A1A1A] text-white px-4 py-4 flex items-center justify-between border-b border-neutral-800 shadow-md">
        <div className="flex flex-col">
          <span className="text-xl font-black tracking-tighter text-[#C21807]">JIGSY'S BREWPUB</span>
          <div className="text-[10px] text-neutral-400 font-bold flex items-center mt-0.5 space-x-1 uppercase tracking-wider">
            <Package size={10} className="text-[#C21807]" />
            <span>Pickup Only • 225 N Enola Rd</span>
          </div>
        </div>

        <button 
          onClick={() => setIsCartOpen(true)}
          className="relative p-2.5 bg-neutral-800 rounded-full hover:bg-neutral-700 transition"
        >
          <ShoppingBag size={18} className="text-[#F3F4F6]" />
          {totalCartCount > 0 && (
            <span className="absolute -top-1 -right-1 bg-[#C21807] text-white text-[10px] font-black rounded-full w-4 h-4 flex items-center justify-center">
              {totalCartCount}
            </span>
          )}
        </button>
      </header>

      {/* VIEWS CANVAS */}
      <main className="flex-1 overflow-y-auto px-4 pt-4 pb-28">
        
        {/* TAB 1: MENU */}
        {activeTab === 'menu' && (
          <div className="space-y-6">
            <div className="bg-gradient-to-br from-[#1F1F1F] to-[#2A2A2A] rounded-xl overflow-hidden border border-neutral-800 shadow-lg p-5 flex flex-col justify-between relative">
              <span className="absolute top-3 right-3 bg-[#C21807] text-white text-[9px] font-black uppercase tracking-wider px-2 py-0.5 rounded">
                App Exclusive
              </span>
              <div className="space-y-1">
                <h3 className="text-lg font-black tracking-tight text-white uppercase">The Enola Mix & Match</h3>
                <p className="text-xs text-neutral-400 leading-snug">Get any Old Forge Tray and a 10-pack of Jumbo Wings for a special combo price.</p>
              </div>
              <div className="mt-4 flex items-center justify-between pt-2 border-t border-neutral-800/60">
                <span className="text-xl font-black text-white">$29.99</span>
                <button 
                  onClick={() => { addToCartDirect(menuData.pizza[0], 'App Combo'); addToCartDirect(menuData.wings[0], 'App Combo'); alert('Bundle loaded into your basket!'); }}
                  className="bg-[#C21807] text-white text-xs font-black px-4 py-2 rounded-lg shadow uppercase tracking-wide"
                >
                  Add Combo
                </button>
              </div>
            </div>

            {Object.entries(menuData).map(([category, items]) => (
              <div key={category} className="space-y-3">
                <h3 className="text-sm font-black uppercase tracking-widest text-neutral-400 border-l-2 border-[#C21807] pl-2">
                  {category === 'pizza' ? 'Old Forge Pizza Trays' : category === 'wings' ? 'Award-Winning Wings' : category === 'subs' ? 'Specialty Subs' : category === 'appetizers' ? 'Starters & Sides' : 'House Brews To-Go'}
                </h3>

                <div className="space-y-3">
                  {items.map(item => (
                    <div key={item.id} className="bg-[#1A1A1A] border border-neutral-800/80 rounded-xl p-4 flex flex-col justify-between shadow-sm relative">
                      {item.tag && (
                        <span className="absolute top-0 right-0 bg-[#C21807] text-white text-[8px] font-black uppercase tracking-widest px-2 py-0.5 rounded-bl-lg">
                          {item.tag}
                        </span>
                      )}
                      <div className="space-y-1">
                        <h4 className="font-extrabold text-base text-white tracking-tight">{item.name}</h4>
                        <p className="text-xs text-neutral-400 leading-normal pr-4">{item.desc}</p>
                      </div>
                      <div className="flex items-center justify-between mt-4 pt-3 border-t border-neutral-800/60">
                        <span className="font-black text-white text-base">${item.price.toFixed(2)}</span>
                        <button 
                          type="button"
                          onClick={() => handleAddClick(item)}
                          className="bg-neutral-800 hover:bg-neutral-700 text-[#F3F4F6] font-bold text-xs px-3.5 py-1.5 rounded-lg border border-neutral-700 transition-all cursor-pointer"
                        >
                          +{item.type === 'pizza' || item.type === 'wings' ? 'Customize' : 'Add'}
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}

        {/* TAB 2: CATERING ENGINE */}
        {activeTab === 'catering' && (
          <div className="space-y-5">
            <div className="space-y-1">
              <h2 className="text-xl font-black text-white uppercase tracking-tight">Catering Setup</h2>
              <p className="text-xs text-neutral-400">Plan events inside our sports basement or configure bulk tray pickup options.</p>
            </div>

            {cateringSubmitted ? (
              <div className="bg-neutral-900 border border-neutral-800 rounded-xl p-6 text-center space-y-3">
                <CheckCircle size={32} className="text-emerald-500 mx-auto" />
                <h4 className="font-bold text-white text-sm">Request Logged</h4>
                <p className="text-xs text-neutral-400">Our coordinators will contact you shortly.</p>
              </div>
            ) : (
              <form onSubmit={e => { e.preventDefault(); setCateringSubmitted(true); }} className="bg-[#1A1A1A] border border-neutral-800 rounded-xl p-4 space-y-4 text-xs">
                <div className="grid grid-cols-2 gap-2">
                  <button type="button" onClick={() => setCateringForm({...cateringForm, location: 'basement'})} className={`p-3 border rounded-lg text-left transition-all ${cateringForm.location === 'basement' ? 'border-[#C21807] bg-[#C21807]/10' : 'border-neutral-800 bg-neutral-900'}`}>
                    <span className="font-black block text-white">Sports Basement</span>
                    <span className="text-[10px] text-neutral-400 block mt-0.5">In-house stadium party.</span>
                  </button>
                  <button type="button" onClick={() => setCateringForm({...cateringForm, location: 'offsite'})} className={`p-3 border rounded-lg text-left transition-all ${cateringForm.location === 'offsite' ? 'border-[#C21807] bg-[#C21807]/10' : 'border-neutral-800 bg-neutral-900'}`}>
                    <span className="font-black block text-white">Bulk Tray Pickup</span>
                    <span className="text-[10px] text-neutral-400 block mt-0.5">Pick up bulk trays at store.</span>
                  </button>
                </div>

                <div className="space-y-3">
                  <div className="space-y-1">
                    <label className="font-bold text-neutral-400">Your Name</label>
                    <input type="text" required value={cateringForm.name} onChange={e => setCateringForm({...cateringForm, name: e.target.value})} className="w-full bg-neutral-900 border border-neutral-800 rounded-lg p-2.5 text-white focus:outline-none" />
                  </div>
                  <div className="space-y-1">
                    <label className="font-bold text-neutral-400">Phone Contact</label>
                    <input type="tel" required value={cateringForm.phone} onChange={e => setCateringForm({...cateringForm, phone: e.target.value})} className="w-full bg-neutral-900 border border-neutral-800 rounded-lg p-2.5 text-white focus:outline-none" />
                  </div>
                  <div className="space-y-1">
                    <label className="font-bold text-neutral-400">Target Date</label>
                    <input type="date" required value={cateringForm.date} onChange={e => setCateringForm({...cateringForm, date: e.target.value})} className="w-full bg-neutral-900 border border-neutral-800 rounded-lg p-2.5 text-white focus:outline-none" style={{colorScheme: 'dark'}} />
                  </div>
                  <div className="space-y-1">
                    <label className="font-bold text-neutral-400 flex justify-between"><span>Est. Guests</span><span className="text-[#C21807] font-black">{cateringForm.guests} People</span></label>
                    <input type="range" min="15" max="150" value={cateringForm.guests} onChange={e => setCateringForm({...cateringForm, guests: parseInt(e.target.value)})} className="w-full mt-2 accent-[#C21807]" />
                  </div>
                </div>

                <div className="bg-neutral-900 rounded-lg p-3 flex justify-between items-center border border-neutral-800">
                  <div>
                    <span className="font-bold text-white block">Est. Tray Setup:</span>
                    <span className="text-[10px] text-neutral-400 block mt-0.5">{Math.ceil(cateringForm.guests / 4)} Trays & {Math.ceil(cateringForm.guests * 2.5)} Wings</span>
                  </div>
                  <span className="text-sm font-black text-[#C21807]">${(cateringForm.guests * 14.50).toFixed(2)}</span>
                </div>

                <button type="submit" className="w-full bg-[#C21807] text-white font-black py-3 rounded-lg uppercase tracking-wider">
                  Request Event Booking
                </button>
              </form>
            )}
          </div>
        )}

        {/* TAB 3: SPACES (FIXED - NO MORE WHITE SCREEN) */}
        {activeTab === 'about' && (
          <div className="space-y-5">
            <div className="space-y-1">
              <h2 className="text-xl font-black text-white uppercase tracking-tight">The Jigsy's Experience</h2>
              <p className="text-xs text-neutral-400">Take a virtual tour of our facility ecosystems.</p>
            </div>

            <div className="space-y-3 text-xs">
              <div className="bg-[#1A1A1A] border border-neutral-800 rounded-xl p-4 space-y-2">
                <div className="flex items-center space-x-2 text-amber-500 font-extrabold uppercase">
                  <Beer size={18} /> <span>Full Bar & Local Taps</span>
                </div>
                <p className="text-neutral-400 leading-relaxed">Our lines run 12 separate fluid taps for crisp independent local craft lagers, stouts, and artisanal ales brewed right on site behind the main bar brickwork.</p>
              </div>
              
              <div className="bg-[#1A1A1A] border border-neutral-800 rounded-xl p-4 space-y-2">
                <div className="flex items-center space-x-2 text-[#C21807] font-extrabold uppercase">
                  <Sun size={18} /> <span>The Outdoor Patio Deck</span>
                </div>
                <p className="text-neutral-400 leading-relaxed">Spacious warm-weather setup out back outfitted with timber tables, protective shading umbrellas, ambient string lighting grids, and full pet accessibility loop paths.</p>
              </div>
              
              <div className="bg-[#1A1A1A] border border-neutral-800 rounded-xl p-4 space-y-2">
                <div className="flex items-center space-x-2 text-sky-400 font-extrabold uppercase">
                  <Tv size={18} /> <span>The Sports Basement Lounge</span>
                </div>
                <p className="text-neutral-400 leading-relaxed">The ultimate game day hub. Our massive lower level features separate service lines and multi-screen high-output HDTV banks optimized for private parties or viewing events.</p>
              </div>
            </div>
          </div>
        )}

        {/* TAB 4: CONTACT & DETAILS */}
        {activeTab === 'contact' && (
          <div className="space-y-5 text-xs">
            <div className="space-y-1">
              <h2 className="text-xl font-black text-white uppercase tracking-tight">Store Logistics</h2>
              <p className="text-xs text-neutral-400">Direct operational metrics and location guides.</p>
            </div>

            <div className="bg-[#1A1A1A] border border-neutral-800 rounded-xl p-4 space-y-4">
              <div className="flex justify-between items-center pb-2 border-b border-neutral-800/60">
                <span className="font-bold text-neutral-400">Street Address</span>
                <span className="font-extrabold text-white text-right">225 N Enola Rd<br/>Enola, PA 17025</span>
              </div>
              <div className="flex justify-between items-center pb-2 border-b border-neutral-800/60">
                <span className="font-bold text-neutral-400">Direct Line</span>
                <a href="tel:7177326808" className="font-black text-[#C21807]">(717) 732-6808</a>
              </div>
              <div className="space-y-2 pt-1">
                <span className="font-bold text-neutral-400 block mb-1">Weekly Store Operating Hours</span>
                <div className="flex justify-between text-[11px]"><span className="text-neutral-500">Mon - Tue</span><span className="text-neutral-500 font-bold">Closed</span></div>
                <div className="flex justify-between text-[11px]"><span className="text-neutral-300">Wed - Thu</span><span className="text-white font-bold">4:00 PM - 9:00 PM</span></div>
                <div className="flex justify-between text-[11px] font-bold text-[#C21807]"><span className="flex items-center">Fri - Sat</span><span>4:00 PM - 10:00 PM</span></div>
                <div className="flex justify-between text-[11px]"><span className="text-neutral-300">Sunday</span><span className="text-white font-bold">1:00 PM - 8:00 PM</span></div>
              </div>
            </div>

            <div className="bg-[#1A1A1A] border border-neutral-800 rounded-xl p-4 shadow">
              {contactSubmitted ? (
                <div className="text-center py-4 font-bold text-emerald-500">Message Dispatched successfully.</div>
              ) : (
                <form onSubmit={e => { e.preventDefault(); setContactSubmitted(true); }} className="space-y-3">
                  <h3 className="font-black text-sm uppercase text-white tracking-tight">Direct Message Terminal</h3>
                  <div className="space-y-1"><label className="font-bold text-neutral-400">Your Email</label><input type="email" required className="w-full bg-neutral-900 border border-neutral-800 rounded-md p-2 text-white focus:outline-none" /></div>
                  <div className="space-y-1"><label className="font-bold text-neutral-400">Feedback Content</label><textarea rows="3" required className="w-full bg-neutral-900 border border-neutral-800 rounded-md p-2 text-white focus:outline-none" placeholder="Type here..."></textarea></div>
                  <button type="submit" className="w-full bg-neutral-800 border border-neutral-700 text-white font-bold py-2 rounded-md uppercase tracking-wider">Send Ticket</button>
                </form>
              )}
            </div>
          </div>
        )}
      </main>

      {/* FOOTER STRIP */}
      {totalCartCount > 0 && activeTab === 'menu' && (
        <div className="absolute bottom-[67px] left-0 right-0 bg-[#C21807] text-white px-4 py-3.5 flex items-center justify-between z-30 shadow-[0_-4px_12px_rgba(0,0,0,0.4)]">
          <div>
            <span className="text-[10px] uppercase font-black tracking-widest text-neutral-200 block">Mobile Basket</span>
            <span className="text-sm font-black tracking-tight">{totalCartCount} Items | ${cartTotal.toFixed(2)}</span>
          </div>
          <button 
            type="button"
            onClick={() => setIsCartOpen(true)}
            className="bg-white text-neutral-900 font-black text-xs px-4 py-2 rounded-lg flex items-center space-x-1 uppercase tracking-wider cursor-pointer"
          >
            <span>Basket</span>
            <ChevronRight size={14} />
          </button>
        </div>
      )}

      {/* CENTER DIALOG FLAVOR CUSTOMIZER */}
      {selectedCustomItem && (
        <div className="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4 backdrop-blur-xs">
          <div className="bg-[#1A1A1A] w-full max-w-xs rounded-2xl p-5 space-y-4 shadow-2xl border border-neutral-800">
            <div className="flex items-start justify-between">
              <div>
                <h3 className="font-black text-base text-white tracking-tight leading-tight">{selectedCustomItem.name}</h3>
                <span className="text-[10px] text-neutral-400 font-bold block mt-0.5">Customize Flavor Options</span>
              </div>
              <button type="button" onClick={() => setSelectedCustomItem(null)} className="p-1 bg-neutral-800 text-neutral-400 rounded-full cursor-pointer"><X size={14} /></button>
            </div>

            {selectedCustomItem.type === 'pizza' ? (
              <div className="space-y-1.5 text-xs">
                <label className="font-black text-neutral-400 block tracking-wider uppercase text-[9px]">Crust Profile</label>
                {['Traditional Old Forge Thick-Crust', 'Thin & Crispy Tavern Crust', 'Double-Crust Stuffed Crust'].map(crust => (
                  <label key={crust} className={`flex items-center space-x-2 border rounded-lg p-2.5 cursor-pointer ${pizzaCrust === crust ? 'border-[#C21807] bg-[#C21807]/5' : 'border-neutral-800 bg-neutral-900'}`}>
                    <input type="radio" name="crust" checked={pizzaCrust === crust} onChange={() => setPizzaCrust(crust)} className="accent-[#C21807]" />
                    <span className="font-bold text-white text-[11px]">{crust}</span>
                  </label>
                ))}
              </div>
            ) : (
              <div className="space-y-1.5 text-xs">
                <label className="font-black text-neutral-400 block tracking-wider uppercase text-[9px]">Sauce Toss</label>
                {['House Mild Sauce', 'Signature Fire Hot', 'Garlic Parmesan Crust Glaze', 'Sweet Smokey BBQ'].map(sauce => (
                  <label key={sauce} className={`flex items-center space-x-2 border rounded-lg p-2.5 cursor-pointer ${wingSauce === sauce ? 'border-[#C21807] bg-[#C21807]/5' : 'border-neutral-800 bg-neutral-900'}`}>
                    <input type="radio" name="sauce" checked={wingSauce === sauce} onChange={() => setWingSauce(sauce)} className="accent-[#C21807]" />
                    <span className="font-bold text-white text-[11px]">{sauce}</span>
                  </label>
                ))}
              </div>
            )}

            <button 
              type="button"
              onClick={() => {
                const specConfig = selectedCustomItem.type === 'pizza' ? pizzaCrust : wingSauce;
                addToCartDirect(selectedCustomItem, specConfig);
              }}
              className="w-full bg-[#C21807] text-white font-black text-xs py-2.5 rounded-xl uppercase tracking-wider shadow cursor-pointer"
            >
              Add To Basket • ${selectedCustomItem.price.toFixed(2)}
            </button>
          </div>
        </div>
      )}

      {/* COMPACT FLOATING BASKET OVERLAY */}
      {isCartOpen && (
        <div className="fixed inset-0 z-50 bg-black/80 flex items-center justify-center p-4">
          <div className="w-full max-w-xs bg-[#1A1A1A] rounded-2xl border border-neutral-800 flex flex-col shadow-2xl overflow-hidden max-h-[70vh]">
            
            <div className="bg-[#222222] text-white p-4 flex items-center justify-between border-b border-neutral-800">
              <div className="flex items-center space-x-2">
                <ShoppingBag size={16} className="text-[#C21807]" />
                <h3 className="font-black text-xs uppercase tracking-wider">Review Basket</h3>
              </div>
              <button type="button" onClick={() => setIsCartOpen(false)} className="p-1 bg-neutral-800 text-neutral-400 rounded-full cursor-pointer">
                <X size={14} />
              </button>
            </div>

            <div className="flex-1 overflow-y-auto p-3 space-y-3 bg-[#121212]">
              {cart.length === 0 ? (
                <div className="text-center py-10 text-neutral-500 font-bold text-[11px]">Your basket is empty.</div>
              ) : (
                cart.map(item => (
                  <div key={item.cartKey} className="bg-[#1A1A1A] border border-neutral-800 rounded-xl p-3 space-y-3 shadow-inner">
                    <div className="space-y-0.5 text-center">
                      <h5 className="font-black text-xs text-white tracking-tight">{item.name}</h5>
                      <p className="text-[9px] text-neutral-400 font-medium italic">{item.details}</p>
                      <span className="text-[#C21807] font-black text-xs block mt-1">${(item.price * item.quantity).toFixed(2)}</span>
                    </div>
                    
                    <div className="grid grid-cols-3 bg-neutral-900 border border-neutral-800 rounded-lg overflow-hidden h-9 text-center items-center">
                      <button 
                        type="button"
                        onClick={() => handleModifyQuantity(item.cartKey, -1)} 
                        className="h-full bg-neutral-800 text-neutral-200 active:bg-[#C21807] active:text-white font-black text-xs border-r border-neutral-800 transition-colors cursor-pointer"
                      >
                        -1
                      </button>
                      <span className="font-black text-white text-xs bg-neutral-900">{item.quantity}</span>
                      <button 
                        type="button"
                        onClick={() => handleModifyQuantity(item.cartKey, 1)} 
                        className="h-full bg-neutral-800 text-neutral-200 active:bg-emerald-600 active:text-white font-black text-xs border-l border-neutral-800 transition-colors cursor-pointer"
                      >
                        +1
                      </button>
                    </div>
                  </div>
                ))
              )}
            </div>

            {cart.length > 0 && (
              <div className="p-3.5 bg-[#161616] border-t border-neutral-800 space-y-3 text-[11px]">
                <div className="space-y-1 text-neutral-400">
                  <div className="flex justify-between"><span>Subtotal</span><span className="font-bold text-white">${cartTotal.toFixed(2)}</span></div>
                  <div className="flex justify-between"><span>Tax & Service</span><span className="font-bold text-white">${(cartTotal * 0.06).toFixed(2)}</span></div>
                  <div className="flex justify-between text-white font-black pt-1.5 mt-1 border-t border-dashed border-neutral-800 text-xs">
                    <span>Total Bill</span><span className="text-[#C21807]">${(cartTotal * 1.06).toFixed(2)}</span>
                  </div>
                </div>
                <button type="button" onClick={() => alert('Order dispatched down to register grids.')} className="w-full bg-[#C21807] text-white font-black py-2 rounded-xl uppercase tracking-wider text-[10px] shadow-md cursor-pointer">
                  Place Pickup Order
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {/* SYSTEM NAVIGATION BAR */}
      <nav className="absolute bottom-0 left-0 right-0 h-[68px] bg-[#1A1A1A] border-t border-neutral-800 grid grid-cols-4 text-center z-30 shadow-[0_-4px_16px_rgba(0,0,0,0.4)]">
        {[
          ['menu', ShoppingBag, 'Order'],
          ['catering', Users, 'Catering'],
          ['about', Info, 'Spaces'],
          ['contact', Phone, 'Contact']
        ].map(([tabId, Icon, label]) => (
          <button 
            key={tabId} type="button" onClick={() => setActiveTab(tabId)}
            className={`flex flex-col items-center justify-center transition-all cursor-pointer ${activeTab === tabId ? 'text-[#C21807]' : 'text-neutral-500'}`}
          >
            <Icon size={18} className={`${activeTab === tabId ? 'scale-110 opacity-100 text-[#C21807]' : 'opacity-60'} transition-all mb-1`} />
            <span className={`text-[10px] font-black uppercase tracking-wider block ${activeTab === tabId ? 'text-white' : 'text-neutral-500'}`}>{label}</span>
          </button>
        ))}
      </nav>

    </div>
  );
}